require "json"
require "option_parser"

require "../lint/config"
require "../lint/diagnostic"
require "../lint/file_discovery"
require "../lint/project_index"
require "../lint/suppressions"
require "../lint/rules/accessibility"
require "../lint/rules/child_props"
require "../lint/rules/class_variables"
require "../lint/rules/component_methods"
require "../lint/rules/css_declaration_lines"
require "../lint/rules/event_payloads"
require "../lint/rules/handlers"
require "../lint/rules/html_method_length"
require "../lint/rules/line_length"
require "../lint/rules/method_missing"
require "../lint/rules/method_length"
require "../lint/rules/money_advice"
require "../lint/rules/nesting_depth"
require "../lint/rules/package_files"
require "../lint/rules/prop_writes"
require "../lint/rules/row_identity"
require "../lint/rules/template_block_lines"
require "../lint/rules/timer_advice"

class LintRunner
  SYNTAX_RULE = Lint::SYNTAX_RULE

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

    diagnostics = begin
      index = Lint::ProjectIndex.build(files, config)
      begin
        raw_diagnostics =
          index.diagnostics +
          Lint::Rules::Handlers.diagnostics(index) +
          Lint::Rules::MethodMissing.diagnostics(index) +
          Lint::Rules::ComponentMethods.diagnostics(index) +
          Lint::Rules::ClassVariables.diagnostics(index) +
          Lint::Rules::MethodLength.diagnostics(index) +
          Lint::Rules::HtmlMethodLength.diagnostics(index) +
          Lint::Rules::LineLength.diagnostics(index) +
          Lint::Rules::CssDeclarationLines.diagnostics(index) +
          Lint::Rules::TemplateBlockLines.diagnostics(index) +
          Lint::Rules::NestingDepth.diagnostics(index) +
          Lint::Rules::PackageFiles.diagnostics(index) +
          Lint::Rules::Accessibility.diagnostics(index) +
          Lint::Rules::ChildProps.diagnostics(index) +
          Lint::Rules::PropWrites.diagnostics(index) +
          Lint::Rules::RowIdentity.diagnostics(index) +
          Lint::Rules::TimerAdvice.diagnostics(index) +
          Lint::Rules::MoneyAdvice.diagnostics(index) +
          Lint::Rules::EventPayloads.diagnostics(index)
        Lint::Suppressions.apply(index, raw_diagnostics)
      ensure
        index.close
      end
    end
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
  rescue ex : File::Error
    error.puts "mochi lint: cannot read source: #{ex.message}"
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
