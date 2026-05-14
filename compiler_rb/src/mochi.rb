# typed: false
# frozen_string_literal: true

require "sorbet-runtime"
require "json"
require "securerandom"
require "optparse"

require_relative "initializer"
require_relative "entrypoints/typechecker"
require_relative "tooling/dev_server"
require_relative "entrypoints/build_main"

module Mochi
  extend T::Sig

  sig { params(component: String, name: String).returns(String) }
  def self.get_attr(component, name)
    "#{component}.element.getAttribute(#{name})"
  end

  sig { params(text: String, substring_to_find: String).returns(T.nilable(Integer)) }
  def self.find_second_last_index(text, substring_to_find)
    last_idx = text.rindex(substring_to_find)

    return -1 unless last_idx && last_idx > 0

    text.rindex(substring_to_find, last_idx - 1)
  end

  sig { params(json_array_str: String).returns(T::Array[String]) }
  def self.js_to_cr_array(json_array_str)
    JSON.parse(json_array_str).map(&:to_s)
  end

  sig { returns(String) }
  def self.generate_build_id
    random_part = SecureRandom.hex(16)
    time_part = Time.now.to_i * 1_000_000_000 + Time.now.nsec
    "#{random_part}#{time_part}"
  end

  sig { params(tag_name: String, i: Integer).void }
  def self.print_cmp_start_separator(tag_name, i)
    puts "==============================  (#{i})  START   #{tag_name}   =================================="
  end

  sig { params(tag_name: String, i: Integer).void }
  def self.print_cmp_end_seperator(tag_name, i)
    puts "==============================  (#{i})   END   #{tag_name}   ===================================="
  end

  sig { void }
  def self.print_separator
    puts "------------------------------------------------------------------------------------"
  end

  class CLI
    extend T::Sig

    sig { void }
    def initialize
      @project_name = T.let("", String)
      @input_dir = T.let("", String)
      @output_dir = T.let("", String)
      @with_mini = T.let(false, T::Boolean)
      @with_tc = T.let(false, T::Boolean)
      @is_dev_server = T.let(false, T::Boolean)
      @dev_server_root = T.let("", String)
      @dev_server_config_path = T.let("", String)
      @is_standalone_typecheck = T.let(false, T::Boolean)
      @keep_granular_build_artifacts = T.let(false, T::Boolean)
      @parser = T.let(nil, T.nilable(OptionParser))
    end

    sig { returns(OptionParser) }
    attr_reader :parser

    sig { params(argv: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
    def parse(argv = ARGV)
      opts = {}

      # Detect explicit subcommands before OptionParser
      if argv.first == "dev"
        @is_dev_server = true
        argv = argv[1..] || []
      end
      if argv.first == "typecheck"
        @is_standalone_typecheck = true
        argv = argv[1..] || []
      end

      OptionParser.new do |p|
        @parser = T.let(p, T.nilable(OptionParser))

        p.banner = "Usage: mochi [options]"

        p.on("-init PROJ_NAME", "--initialize=PROJ_NAME", "Initialize a new mochi project") do |k|
          @project_name = k
        end

        p.on("-i IN_DIR", "--input_dir=IN_DIR", "Input directory to read from") do |i|
          @input_dir = i
        end

        p.on("-o OUT_DIR", "--output_dir=OUT_DIR", "Output directory to write into") do |o|
          @output_dir = o
        end

        p.on("--minimize", "Minimize output") do
          @with_mini = true
        end

        p.on("--typecheck", "Run typechecks with Sorbet") do
          @with_tc = true
        end

        p.on("--keep_granular_build_artifacts", "Preserves all granular build artifacts (meant for developers working on Mochi)") do
          @keep_granular_build_artifacts = true
        end

        p.on("-h", "--help", "Show this help") do
          puts p
          exit
        end

        p.on("--dev", "Launch dev server") do
          @is_dev_server = true
        end

        p.on("--root=ROOT_DIR", "Root directory for the dev server") do |root_dir|
          @dev_server_root = root_dir
        end

        p.on("--config=DEV_CONFIG", "Path to dev server config file") do |config_path|
          @dev_server_config_path = config_path
        end

        p.on("--experimental-new-engine", "Use the new experimental rendering engine") do
          # NO OP
        end

        p.on_tail do
          # NO OP
        end
      end.parse!(argv)

      opts
    end

    sig { params(argv: T::Array[String]).void }
    def run(argv = ARGV)
      begin
        parse(argv)
      rescue OptionParser::InvalidOption => e
        STDERR.puts "ERROR: Unknown option: #{e.args.first}"
        STDERR.puts @parser if @parser
        exit 1
      rescue OptionParser::MissingArgument => e
        STDERR.puts "ERROR: Missing argument for #{e.args.first}"
        STDERR.puts @parser if @parser
        exit 1
      end

      dispatch
    end

    sig { void }
    def dispatch
      if @is_dev_server
        if @dev_server_config_path.empty? || @dev_server_root.empty?
          puts "No arguments provided, intended usage:"
          puts "  mochi dev --config=\u003c/path/to/dev_server_config.json\u003e --root=\u003c/path/to/ruby/src\u003e"
          exit 1
        end
        Mochi::DevServer.new.start(@dev_server_root, @dev_server_config_path)
        return
      end

      if @is_standalone_typecheck
        Typechecker.new.run
        return
      end

      puts "Mochi v0.3"
      if !@project_name.empty?
        Initializer.new(@project_name)
      else
        BuildMain.new.build(
          @input_dir,
          @output_dir,
          @parser,
          @with_tc,
          @with_mini,
          @keep_granular_build_artifacts,
        )
      end
    end
  end
end

Mochi::CLI.new.run if __FILE__ == $0
