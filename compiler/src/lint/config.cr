require "path"
require "yaml"

require "./diagnostic"
require "./rule_registry"

module Lint
  class ConfigError < Exception
    getter path : String
    getter line : Int32?
    getter column : Int32?

    def initialize(@path : String, message : String, @line : Int32? = nil, @column : Int32? = nil)
      super(message)
    end

    def location : String
      if line = @line
        "#{@path}:#{line}:#{@column || 1}"
      else
        @path
      end
    end
  end

  # Root behavior:
  # - An explicit -i path is the project boundary.
  # - Without -i, a discovered or explicit config's directory becomes the
  #   project root.
  # - Config globs always resolve relative to the config directory. The project
  #   boundary intersects those matches, so an explicit -i below a config root
  #   must be named by the include globs.
  class Config
    CONFIG_FILE        = ".mochi-lint.yml"
    SCHEMA_VERSION     = 1_i64
    DEFAULT_INCLUDE    = ["lib/**/*.rb"]
    PRUNED_DIRECTORIES = [".git", "node_modules", "vendor", "build", "dist", "coverage"]
    ASSET_DIRECTORIES  = ["public"]

    getter path : String?
    getter root : String
    getter project_root : String
    getter include_globs : Array(String)
    getter exclude_globs : Array(String)
    getter rules : Hash(String, RuleSettings)

    def initialize(
      @path : String?,
      @root : String,
      @project_root : String,
      @include_globs : Array(String),
      @exclude_globs : Array(String),
      @rules : Hash(String, RuleSettings),
    )
    end

    def self.load(
      project_root : String,
      project_explicit : Bool,
      explicit_config : String?,
      working_directory : String,
    ) : Config
      requested_root = canonical_dir(project_root)
      config_path = if explicit_config
                      resolved = File.expand_path(explicit_config, working_directory)
                      unless File.file?(resolved)
                        reason = File.exists?(resolved) ? "config path is not a file" : "config file not found"
                        raise ConfigError.new(resolved, reason)
                      end
                      File.realpath(resolved)
                    else
                      discover(requested_root)
                    end

      if config_path
        config_root = File.realpath(File.dirname(config_path))
        effective_project = project_explicit ? requested_root : config_root
        unless compatible?(effective_project, config_root)
          raise ConfigError.new(
            config_path,
            "config directory '#{config_root}' is not compatible with project '#{effective_project}'",
          )
        end
        parse_file(config_path, effective_project, config_root)
      else
        Config.new(
          nil,
          requested_root,
          requested_root,
          DEFAULT_INCLUDE.dup,
          [] of String,
          RuleRegistry.default_rules,
        )
      end
    end

    def settings_for(rule : String) : RuleSettings
      @rules[rule]? || raise KeyError.new("unknown lint rule '#{rule}'")
    end

    def level_for(rule : String) : RuleLevel
      settings_for(rule).level
    end

    def enabled?(rule : String) : Bool
      settings_for(rule).enabled?
    end

    def severity_for(rule : String) : Severity?
      settings_for(rule).severity
    end

    def include_match?(relative_path : String) : Bool
      @include_globs.any? { |pattern| File.match?(pattern, relative_path) }
    end

    def exclude_match?(relative_path : String) : Bool
      @exclude_globs.any? { |pattern| File.match?(pattern, relative_path) }
    end

    private def self.discover(start_dir : String) : String?
      current = start_dir
      loop do
        candidate = File.join(current, CONFIG_FILE)
        if File.file?(candidate)
          return File.realpath(candidate)
        elsif File.exists?(candidate) || File.symlink?(candidate)
          raise ConfigError.new(candidate, "config path is not a file")
        end

        break if File.exists?(File.join(current, ".git"))

        parent = File.dirname(current)
        break if parent == current
        current = parent
      end
      nil
    end

    private def self.parse_file(path : String, project_root : String, config_root : String) : Config
      content = begin
        File.read(path)
      rescue ex : File::Error
        raise ConfigError.new(path, "cannot read config: #{ex.message}")
      end

      documents = begin
        YAML::Nodes.parse_all(content)
      rescue ex : YAML::ParseException
        raise ConfigError.new(path, "invalid YAML: #{ex.message}", ex.line_number, ex.column_number)
      end
      unless documents.size == 1
        raise ConfigError.new(path, "config must contain exactly one YAML document")
      end

      root_node = documents.first.nodes.first?
      raise ConfigError.new(path, "config must be a mapping") unless root_node
      top_mapping = require_mapping(root_node, path, "config")
      entries = mapping_entries(top_mapping, path, "config")

      version : Int64? = nil
      include_globs : Array(String)? = nil
      exclude_globs : Array(String)? = nil
      overrides = {} of String => RuleSettings

      entries.each do |key, key_node, value_node|
        case key
        when "version"
          version = parse_version(value_node, path)
        when "include"
          include_globs = parse_string_list(value_node, path, "include")
        when "exclude"
          exclude_globs = parse_string_list(value_node, path, "exclude")
        when "rules"
          overrides = parse_rules(value_node, path)
        else
          config_error(key_node, path, "unknown config key '#{key}'")
        end
      end

      unless version
        config_error(top_mapping, path, "missing required key 'version'")
      end

      rules = RuleRegistry.default_rules
      overrides.each { |id, settings| rules[id] = settings }

      Config.new(
        path,
        config_root,
        project_root,
        include_globs || DEFAULT_INCLUDE.dup,
        exclude_globs || [] of String,
        rules,
      )
    end

    private def self.parse_version(node : YAML::Nodes::Node, path : String) : Int64
      scalar = require_scalar(node, path, "version")
      unless scalar.style.plain?
        config_error(scalar, path, "version must be the integer 1")
      end
      version = scalar.value.to_i64?
      unless version
        config_error(scalar, path, "version must be the integer 1")
      end
      unless version == SCHEMA_VERSION
        config_error(scalar, path, "unsupported config version '#{version}'; expected 1")
      end
      version
    end

    private def self.parse_string_list(node : YAML::Nodes::Node, path : String, context : String) : Array(String)
      sequence = require_sequence(node, path, context)
      values = [] of String
      sequence.nodes.each do |item|
        scalar = require_scalar(item, path, "#{context} entries")
        value = scalar.value
        validate_glob!(value, scalar, path, context)
        values << value
      end
      values
    end

    private def self.validate_glob!(value : String, node : YAML::Nodes::Node, path : String, context : String) : Nil
      if value.empty?
        config_error(node, path, "#{context} glob must not be empty")
      end
      if value.starts_with?("/") || Path[value].absolute?
        config_error(node, path, "#{context} glob '#{value}' must be relative to the config directory")
      end
      if value.split('/').includes?("..")
        config_error(node, path, "#{context} glob '#{value}' must not escape the config directory")
      end
      begin
        File.match?(value, value)
      rescue File::BadPatternError
        config_error(node, path, "malformed #{context} glob '#{value}'")
      end
    end

    private def self.parse_rules(node : YAML::Nodes::Node, path : String) : Hash(String, RuleSettings)
      mapping = require_mapping(node, path, "rules")
      entries = mapping_entries(mapping, path, "rules")
      overrides = {} of String => RuleSettings
      entries.each do |id, key_node, value_node|
        definition = RuleRegistry[id]?
        definition ||= config_error(key_node, path, "unknown rule '#{id}'")
        unless definition.configurable?
          config_error(key_node, path, "rule '#{id}' is always enabled and cannot be configured")
        end
        overrides[id] = parse_rule_settings(definition, value_node, path)
      end
      overrides
    end

    private def self.parse_rule_settings(
      definition : RuleDefinition,
      node : YAML::Nodes::Node,
      path : String,
    ) : RuleSettings
      level : RuleLevel? = nil
      if node.is_a?(YAML::Nodes::Scalar)
        level = RuleLevel.parse?(node.value)
        level ||= config_error(node, path, "invalid severity '#{node.value}' for rule '#{definition.id}'")
        return RuleSettings.new(level, definition.default_options)
      end

      mapping = require_mapping(node, path, "rule '#{definition.id}'")
      entries = mapping_entries(mapping, path, "rule '#{definition.id}'")
      values = definition.default_options

      entries.each do |key, key_node, value_node|
        if key == "severity"
          scalar = require_scalar(value_node, path, "severity")
          level = RuleLevel.parse?(scalar.value)
          level ||= config_error(scalar, path, "invalid severity '#{scalar.value}' for rule '#{definition.id}'")
        elsif definition.options[key]?
          scalar = require_scalar(value_node, path, "option '#{key}'")
          unless scalar.style.plain?
            config_error(scalar, path, "option '#{key}' for rule '#{definition.id}' must be a positive integer")
          end
          value = scalar.value.to_i?
          unless value && value > 0
            config_error(scalar, path, "option '#{key}' for rule '#{definition.id}' must be a positive integer")
          end
          values[key] = value
        else
          config_error(key_node, path, "unknown option '#{key}' for rule '#{definition.id}'")
        end
      end

      unless level
        config_error(mapping, path, "rule '#{definition.id}' requires a severity")
      end
      RuleSettings.new(level, values)
    end

    private def self.require_mapping(
      node : YAML::Nodes::Node,
      path : String,
      context : String,
    ) : YAML::Nodes::Mapping
      unless node.is_a?(YAML::Nodes::Mapping)
        config_error(node, path, "#{context} must be a mapping")
      end
      node
    end

    private def self.require_sequence(
      node : YAML::Nodes::Node,
      path : String,
      context : String,
    ) : YAML::Nodes::Sequence
      unless node.is_a?(YAML::Nodes::Sequence)
        config_error(node, path, "#{context} must be a sequence")
      end
      node
    end

    private def self.require_scalar(
      node : YAML::Nodes::Node,
      path : String,
      context : String,
    ) : YAML::Nodes::Scalar
      unless node.is_a?(YAML::Nodes::Scalar)
        config_error(node, path, "#{context} must be a string")
      end
      node
    end

    private def self.mapping_entries(
      mapping : YAML::Nodes::Mapping,
      path : String,
      context : String,
    ) : Array(Tuple(String, YAML::Nodes::Node, YAML::Nodes::Node))
      entries = [] of Tuple(String, YAML::Nodes::Node, YAML::Nodes::Node)
      seen = {} of String => Bool
      mapping.each do |key, value|
        scalar = require_scalar(key, path, "#{context} keys")
        name = scalar.value
        if seen[name]?
          config_error(key, path, "duplicate key '#{name}' in #{context}")
        end
        seen[name] = true
        entries << {name, key, value}
      end
      entries
    end

    private def self.config_error(node : YAML::Nodes::Node, path : String, message : String) : NoReturn
      raise ConfigError.new(path, message, node.start_line, node.start_column)
    end

    private def self.canonical_dir(path : String) : String
      File.realpath(File.expand_path(path))
    end

    private def self.compatible?(project_root : String, config_root : String) : Bool
      inside?(project_root, config_root) || inside?(config_root, project_root)
    end

    private def self.inside?(path : String, root : String) : Bool
      relative = Path[path].relative_to?(root)
      return false unless relative
      value = relative.to_s
      value == "." || (!Path[value].absolute? && value != ".." && !value.starts_with?("../"))
    end
  end
end
