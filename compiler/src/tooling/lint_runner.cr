require "json"
require "option_parser"

require "../lint/config"
require "../lint/diagnostic"
require "../lint/file_discovery"
require "../tree-sitter/ruby_parser"

class LintRunner
  SYNTAX_RULE = "ruby/syntax"

  class InvocationError < Exception
  end

  record Options,
    help : Bool,
    project : String?,
    config : String?,
    format : String,
    help_text : String

  def run(
    args : Array(String),
    output : IO = STDOUT,
    error : IO = STDERR,
    working_directory : String = Dir.current,
  ) : Int32
    options = parse_options(args)
    if options.help
      output.puts options.help_text
      return 0
    end

    project_root = resolve_project(options.project, working_directory)
    config = Lint::Config.load(project_root, !options.project.nil?, options.config, working_directory)
    files = Lint::FileDiscovery.discover(config.project_root, config)
    if files.empty?
      raise InvocationError.new("no Ruby source files matched the lint configuration for #{config.project_root}")
    end

    diagnostics = lint_files(files, config)
    if options.format == "json"
      output.puts render_json(diagnostics)
    else
      diagnostics.each { |diagnostic| output.puts diagnostic.to_text }
    end

    diagnostics.empty? ? 0 : 1
  rescue ex : Lint::ConfigError
    error.puts "mochi lint: #{ex.location}: #{ex.message}"
    2
  rescue ex : InvocationError
    error.puts "mochi lint: #{ex.message}"
    2
  rescue ex
    error.puts "mochi lint: internal error: #{ex.message}"
    2
  end

  private def parse_options(args : Array(String)) : Options
    project : String? = nil
    config : String? = nil
    format = "text"
    format_seen = false
    help = false

    parser = OptionParser.new
    parser.banner = "Usage: mochi lint [options]"
    parser.on("-i PROJECT", "--input=PROJECT", "Project directory to lint (default: current directory)") do |value|
      project = select_once("project", project, value)
    end
    parser.on("--config=PATH", "Path to a lint configuration file") do |value|
      config = select_once("config", config, value)
    end
    parser.on("--format=FORMAT", "Output format: text (default) or json") do |value|
      format = select_once("format", format_seen ? format : nil, value)
      format_seen = true
    end
    parser.on("-h", "--help", "Show this help") do
      help = true
    end
    parser.invalid_option do |flag|
      raise InvocationError.new("unknown option: #{flag}")
    end
    parser.missing_option do |flag|
      raise InvocationError.new("missing argument for #{flag}")
    end
    parser.parse(args)

    unless format.in?("text", "json")
      raise InvocationError.new("unsupported format '#{format}'; choose text or json")
    end
    unless args.empty?
      raise InvocationError.new("unexpected argument '#{args.first}'")
    end

    Options.new(help, project, config, format, parser.to_s)
  end

  private def select_once(name : String, current : String?, value : String) : String
    if current && current != value
      raise InvocationError.new("conflicting #{name} values '#{current}' and '#{value}'")
    end
    value
  end

  private def resolve_project(project : String?, working_directory : String) : String
    requested = project || working_directory
    root = File.expand_path(project || ".", working_directory)
    unless Dir.exists?(root)
      raise InvocationError.new("project directory not found: #{requested}")
    end
    if File.symlink?(root)
      raise InvocationError.new("project directory cannot be a symlink: #{requested}")
    end
    File.realpath(root)
  end

  private def lint_files(files : Array(Lint::SourceFile), config : Lint::Config) : Array(Lint::Diagnostic)
    diagnostics = [] of Lint::Diagnostic
    parser = TreeSitter::RubyParser.new

    files.each do |file|
      source = begin
        File.read(file.absolute_path)
      rescue ex
        raise InvocationError.new("cannot read #{file.relative_path}: #{ex.message}")
      end
      diagnostics.concat(syntax_diagnostics(source, file.relative_path, parser, config))
    end

    diagnostics.sort_by! do |diagnostic|
      {
        diagnostic.path,
        diagnostic.start_byte,
        diagnostic.rule,
        diagnostic.message,
        diagnostic.end_byte,
        diagnostic.severity.label,
        diagnostic.suggestion || "",
      }
    end
    diagnostics
  end

  private def syntax_diagnostics(
    source : String,
    relative_path : String,
    parser : TreeSitter::RubyParser,
    config : Lint::Config,
  ) : Array(Lint::Diagnostic)
    return [] of Lint::Diagnostic unless config.enabled?(SYNTAX_RULE)

    severity = config.severity_for(SYNTAX_RULE) || Lint::Severity::Error
    tree = parser.parse(source)
    root = tree.root_node
    return [] of Lint::Diagnostic unless root.has_error?

    diagnostic = first_syntax_error(root, relative_path, severity) ||
                 diagnostic_for(root, relative_path, severity, "Ruby syntax error")
    [diagnostic]
  end

  private def first_syntax_error(
    node : TreeSitter::Node,
    relative_path : String,
    severity : Lint::Severity,
  ) : Lint::Diagnostic?
    return nil if node.null?

    if node.type == "ERROR"
      missing = first_missing(node)
      if missing
        return diagnostic_for(missing, relative_path, severity, "missing '#{missing.type}'")
      end
      return diagnostic_for(node, relative_path, severity, "Ruby syntax error")
    end

    if node.missing?
      return diagnostic_for(node, relative_path, severity, "missing '#{node.type}'")
    end

    node.each_child do |child|
      found = first_syntax_error(child, relative_path, severity)
      return found if found
    end
    nil
  end

  private def first_missing(node : TreeSitter::Node) : TreeSitter::Node?
    return node if node.missing?

    node.each_child do |child|
      found = first_missing(child)
      return found if found
    end
    nil
  end

  private def diagnostic_for(
    node : TreeSitter::Node,
    relative_path : String,
    severity : Lint::Severity,
    message : String,
  ) : Lint::Diagnostic
    start_point = node.start_point
    end_point = node.end_point
    Lint::Diagnostic.new(
      path: relative_path,
      start_line: start_point.row.to_i + 1,
      start_column: start_point.column.to_i + 1,
      end_line: end_point.row.to_i + 1,
      end_column: end_point.column.to_i + 1,
      start_byte: node.start_byte,
      end_byte: node.end_byte,
      severity: severity,
      rule: SYNTAX_RULE,
      message: message,
    )
  end

  private def render_json(diagnostics : Array(Lint::Diagnostic)) : String
    JSON.build do |json|
      json.object do
        json.field "schema_version", 1
        json.field "diagnostics" do
          json.array do
            diagnostics.each { |diagnostic| diagnostic.to_json(json) }
          end
        end
      end
    end
  end
end
