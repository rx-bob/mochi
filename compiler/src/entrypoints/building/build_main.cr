require "./builder_man"
require "file"
require "file_utils"
require "../../../../fragments/vendor/libpftrace/bindings/crystal/src/pftrace"
require "../../sorbet/project_typechecker"
require "./trace_helper"

class BuildMain
  include TraceHelper

  def setup(builder_man : BuilderMan)
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
    batt_time = Time.measure do
      CoreBattery.generate(builder_man.ruby_src_dir)
    end
    puts "> Batteries took #{batt_time.total_milliseconds.to_i}ms"
  end

  def build(
    input_dir : String,
    output_dir : String,
    with_tc : Bool,
    keep_granular_build_artifacts : Bool,
  )
    trace = Pftrace::Trace.new("mochi_build.pftrace")
    start_time = Time.monotonic.total_nanoseconds.to_u64
    sequence_id = 1_u32

    trace.write_clock_snapshot(start_time)
    trace.write_process_descriptor(pid: Process.pid.to_i32, name: "MochiBuild", uuid: 100_u64)
    trace.write_thread_descriptor(pid: Process.pid.to_i32, tid: Process.pid.to_i32, name: "MainThread", uuid: 101_u64, parent_uuid: 100_u64)

    # 1. Prepare Input / Output directories
    if input_dir.empty? || output_dir.empty?
      puts "Input & output directory need to be specified"
      exit 1
    end

    print_separator
    puts "1. input_dir:#{input_dir}, output_dir:#{output_dir}"
    prepare_output_dir(output_dir)
    builder_man = BuilderMan.new(input_dir)

    # steps 2-4
    puts "BuildID: #{builder_man.build_id}"
    puts "Working Dir: #{Dir.current}"

    trace_slice(trace, "Setup", sequence_id, "build") do
      setup(builder_man)
    end

    print_separator
    if with_tc
      puts "4b. Typechecking Ruby components"
      unless ProjectTypechecker.new(builder_man.ruby_src_dir).typecheck
        raise "Sorbet typecheck failed"
      end
    else
      puts "> Typecheck skipped (--typecheck not set)"
    end

    print_separator
    transpiler = Compiler.new
    puts "5. Transpiling Mochi Components"

    mochi_comp_time = Time.measure do
      trace_slice(trace, "Transpiling", sequence_id, "build") do
        transpiler.transpile_directory("#{builder_man.pre_tp_dir}/lib", output_dir, builder_man, trace, sequence_id)
      end
    end
    puts "> Compilation took #{mochi_comp_time.total_milliseconds.to_i}ms"

    print_separator
    puts "6. Copying Entry Page"
    copy_entry_page(input_dir, output_dir)

    if !keep_granular_build_artifacts
      puts "removing granular build artifacts"

      remove_directory("#{builder_man.build_dir}/pre_tp")
      remove_directory("#{builder_man.build_dir}/src")
    end

    trace.close
    puts "Trace saved to mochi_build.pftrace"

    total_ms = (Time.monotonic.total_nanoseconds.to_u64 - start_time) // 1_000_000
    puts "> Total build took #{total_ms}ms"

    print_separator
    puts "Done."
  end

  private def prepare_output_dir(output_dir : String)
    Dir.mkdir_p(output_dir)
    remove_directory(File.join(output_dir, "components"))
    File.delete(File.join(output_dir, "bundle.js")) if File.exists?(File.join(output_dir, "bundle.js"))
  end

  private def copy_entry_page(input_dir : String, output_dir : String)
    source = File.join(input_dir, "index.html")
    unless File.file?(source)
      puts "> No index.html in #{input_dir}; skipped"
      return
    end

    FileUtils.cp(source, File.join(output_dir, "index.html"))
    puts "> Copied index.html"
  end

  def remove_directory(dir_path : String)
    if dir_path.size > 5 # safety guard so nobody pipes sth like "/" in there
      begin
        FileUtils.rm_rf(dir_path)
      rescue e : Exception
        puts "Unable to remove directory #{dir_path}: #{e.message}"
      end
    end
  end
end
