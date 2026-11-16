require "path"

require "./config"

module Lint
  record SourceFile, absolute_path : String, relative_path : String

  class FileDiscovery
    def self.discover(project_root : String, config : Config) : Array(SourceFile)
      walk_root = intersection_root(project_root, config.root, config.path)
      selected = {} of String => SourceFile
      walk(walk_root, project_root, config, selected)
      selected.values.sort_by { |source| {source.relative_path, source.absolute_path} }
    end

    private def self.intersection_root(project_root : String, config_root : String, path : String?) : String
      return project_root if inside?(project_root, config_root)
      return config_root if inside?(config_root, project_root)
      raise ConfigError.new(
        path || config_root,
        "config directory '#{config_root}' is not compatible with project '#{project_root}'",
      )
    end

    private def self.walk(
      directory : String,
      project_root : String,
      config : Config,
      selected : Hash(String, SourceFile),
    ) : Nil
      Dir.children(directory).sort.each do |name|
        path = File.join(directory, name)
        next if File.symlink?(path)

        if File.directory?(path)
          next if Config::PRUNED_DIRECTORIES.includes?(name)
          next if Config::ASSET_DIRECTORIES.includes?(name)
          walk(path, project_root, config, selected)
        elsif File.file?(path) && File.extname(path).downcase == ".rb"
          next unless inside?(path, project_root) && inside?(path, config.root)

          relative_config = Path[path].relative_to(config.root).to_s
          next unless config.include_match?(relative_config)
          next if config.exclude_match?(relative_config)

          real_path = File.realpath(path)
          next unless inside?(real_path, project_root) && inside?(real_path, config.root)

          relative_project = Path[real_path].relative_to(project_root).to_s
          selected[real_path] ||= SourceFile.new(real_path, relative_project)
        end
      end
    end

    private def self.inside?(path : String, root : String) : Bool
      relative = Path[path].relative_to?(root)
      return false unless relative
      value = relative.to_s
      value == "." || (!Path[value].absolute? && value != ".." && !value.starts_with?("../"))
    end
  end
end
