# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "fileutils"

require_relative "building/builder_man"
require_relative "../ruby/ruby_rewriter"
require_relative "../batteries/sorbet_types_bat"
require_relative "../batteries/core_battery"
require_relative "../opal/opal_runtime_generator"
require_relative "../js/js_logger"
require_relative "transpiler"

class BuildMain
  extend T::Sig

  sig { params(builder_man: BuilderMan).void }
  def setup(builder_man)
    build_dir = builder_man.build_dir

    print_separator
    puts "2. Copying Ruby code to pre_tp"
    builder_man.copy_ruby_code_to_pre_tp
    puts "Ruby code copied to #{builder_man.pre_tp_dir}"

    # built-in components (need to be compiled)
    rb_rewriter = RubyRewriter.new

    builtin_feather_icon_comp = rb_rewriter.gen_builtin_component_feather_icon
    File.write("#{builder_man.pre_tp_dir}/lib/mochi_builtin_feathericon_comp.rb", builtin_feather_icon_comp)

    builtin_mochi_router = rb_rewriter.gen_builtin_mochi_router
    File.write("#{builder_man.pre_tp_dir}/lib/mochi_router.rb", builtin_mochi_router)

    builtin_route_comp = rb_rewriter.gen_builtin_route_component
    File.write("#{builder_man.pre_tp_dir}/lib/mochi_builtin_route_comp.rb", builtin_route_comp)

    print_separator
    puts "3. Copying pre_tp to src for transpilation"
    builder_man.copy_ruby_code_base

    print_separator
    puts "4. Packing in Batteries"
    batt_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    SorbetTypesBat.generate(builder_man.ruby_src_dir)
    CoreBattery.generate(builder_man.ruby_src_dir)
    batt_time = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - batt_start) * 1000).to_i
    puts "> Batteries took #{batt_time}ms"
  end

  sig do
    params(
      input_dir: String,
      output_dir: String,
      parser: T.untyped,
      with_tc: T::Boolean,
      with_mini: T::Boolean,
      keep_granular_build_artifacts: T::Boolean
    ).void
  end
  def build(input_dir, output_dir, parser, with_tc, with_mini, keep_granular_build_artifacts)
    # 1. Prepare Input / Output directories
    if input_dir.empty? || output_dir.empty?
      puts "Input & output directory need to be specified"
      exit 1
    end

    print_separator
    puts "1. input_dir:#{input_dir}, output_dir:#{output_dir}"
    builder_man = BuilderMan.new(input_dir)

    # steps 2-4
    puts "BuildID: #{builder_man.build_id}"
    puts "Working Dir: #{Dir.pwd}"

    setup_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    setup(builder_man)
    setup_time = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - setup_start) * 1000).to_i
    puts "> Setup took #{setup_time}ms"

    print_separator
    transpiler = Compiler.new
    puts "5. Transpiling Mochi Components"

    comp_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    transpiler.transpile_directory("#{builder_man.pre_tp_dir}/lib", output_dir, builder_man)
    comp_time = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - comp_start) * 1000).to_i
    puts "> Compilation took #{comp_time}ms"

    print_separator
    puts "6. Generating Opal Runtime"

    rt_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    opal_rt_gen = OpalRuntimeGenerator.new
    opal_rt_gen.generate(builder_man.build_dir)
    rt_time = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - rt_start) * 1000).to_i
    puts "> Opal RT gen took #{rt_time}ms"

    step_nr = 7

    print_separator
    puts "#{step_nr}. Bundling"
    step_nr += 1

    bundle_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    FileUtils.cp("#{builder_man.build_dir}/runtime.js", "#{output_dir}/runtime.js")
    FileUtils.cp("#{builder_man.build_dir}/bundle.js", "#{output_dir}/bundle.js")

    bundle_js = File.read("#{output_dir}/bundle.js")
    File.write("#{output_dir}/bundle.js", "#{bundle_js}\n#{JsLoggerGenerator.generate}")
    bundle_time = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - bundle_start) * 1000).to_i
    puts "> Bundling took #{bundle_time}ms"

    print_separator
    puts "#{step_nr}. Minify the output: #{with_mini}"
    step_nr += 1

    mini_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if with_mini
      unless system("which swc > /dev/null 2>&1")
        STDERR.puts "Error: swc is not installed. Please run 'npm install -g @swc/cli @swc/core'."
        exit 1
      end
      system("npx swc \"#{output_dir}/runtime.js\" -o \"#{output_dir}/runtime.js\"")
    end
    mini_time = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - mini_start) * 1000).to_i
    puts "> Minification took #{mini_time}ms"

    unless keep_granular_build_artifacts
      puts "removing granular build artifacts"

      remove_file("#{builder_man.build_dir}/ruby.js")
      remove_directory("#{builder_man.build_dir}/pre_tp")
      remove_directory("#{builder_man.build_dir}/src")
    end

    print_separator
    puts "Done."
  end

  sig { params(file_path: String).void }
  def remove_file(file_path)
    File.delete(file_path)
  rescue Errno::ENOENT
    puts "Unable to remove file, as I couldnt find it: #{file_path}"
  end

  sig { params(dir_path: String).void }
  def remove_directory(dir_path)
    if dir_path.size > 5
      FileUtils.rm_rf(dir_path)
    end
  rescue => e
    puts "Unable to remove directory #{dir_path}: #{e.message}"
  end

  private

  sig { void }
  def print_separator
    puts "------------------------------------------------------------------------------------"
  end
end
