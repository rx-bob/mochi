require "./builder_man"
require "file"
require "file_utils"
require "../../../../fragments/vendor/libpftrace/bindings/crystal/src/pftrace"
require "../../generated/app_router_rb"
require "../../generated/store_rb"
require "../../generated/money_rb"
require "../../generated/format_rb"
require "../../generated/collections_rb"
require "../../generated/pointer_rb"
require "../../generated/layout_rb"
require "../../generated/shortcuts_rb"
require "../../generated/drag_rb"
require "../../generated/files_rb"
require "../../generated/json_rb"
require "../../generated/time_rb"
require "../../generated/download_rb"
require "../../tooling/installation_paths"
require "../../sorbet/project_typechecker"
require "./trace_helper"
require "../../gvm/capacity_config"

class BuildMain
  include TraceHelper

  STATIC_ASSET_EXTS = {".css", ".svg", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2"}

  def setup(builder_man : BuilderMan, prepare_typecheck_tree : Bool = true)
    print_separator
    puts "2. Copying Ruby code to pre_tp"
    builder_man.copy_ruby_code_to_pre_tp
    puts "Ruby code copied to #{builder_man.pre_tp_dir}"

    all_rb_sources = builder_man.all_staged_ruby_source

    rb_rewriter = RubyRewriter.new

    if all_rb_sources.includes?("MochiIcons.icon") || all_rb_sources.includes?("FeatherIcon") || all_rb_sources.includes?("feather-icon")
      builder_man.register_generated_ruby_source(
        "#{builder_man.pre_tp_dir}/lib/mochi_builtin_icon.rb",
        rb_rewriter.gen_builtin_icon
      )
    end

    if all_rb_sources.includes?("feather-icon") || all_rb_sources.includes?("FeatherIcon")
      builtin_feather_icon_comp = rb_rewriter.gen_builtin_component_feather_icon
      builder_man.register_generated_ruby_source(
        "#{builder_man.pre_tp_dir}/lib/mochi_builtin_feathericon_comp.rb",
        builtin_feather_icon_comp
      )
    end

    if all_rb_sources.includes?("mochi-router") || all_rb_sources.includes?("mochi-route") || all_rb_sources.includes?("MochiRouter")
      builtin_mochi_router = rb_rewriter.gen_builtin_mochi_router
      builder_man.register_generated_ruby_source(
        "#{builder_man.pre_tp_dir}/lib/mochi_router.rb",
        builtin_mochi_router
      )

      builtin_route_comp = rb_rewriter.gen_builtin_route_component
      builder_man.register_generated_ruby_source(
        "#{builder_man.pre_tp_dir}/lib/mochi_builtin_route_comp.rb",
        builtin_route_comp
      )
    end

    # Route matching is optional Ruby bytecode. Applications that never
    # mention AppRouter do not pay for a route table or parameter parser.
    if all_rb_sources.includes?("AppRouter")
      builder_man.register_generated_ruby_source(
        "#{builder_man.pre_tp_dir}/lib/mochi_builtin_app_router.rb",
        AppRouterRbFragment.get_ruby_code
      )
    end

    # Storage defaults, effective-change checks, and error fallback are optional
    # Ruby bytecode. The host subscription primitive stays in the core because
    # the VM already owns storage.
    if all_rb_sources.includes?("MochiStore")
      builder_man.register_generated_ruby_source(
        "#{builder_man.pre_tp_dir}/lib/mochi_builtin_store.rb",
        MochiStoreRbFragment.get_ruby_code
      )
    end

    # Exact money arithmetic is ordinary Ruby bytecode. Emit it only for
    # applications that mention the helper; the package graph attaches it to
    # the components that depend on it.
    if all_rb_sources.includes?("MochiMoney")
      builder_man.register_generated_ruby_source(
        "#{builder_man.pre_tp_dir}/lib/mochi_builtin_money.rb",
        MochiMoneyRbFragment.get_ruby_code
      )
    end

    # Browser-backed formatting is optional Ruby bytecode plus a host adapter.
    # The package graph reports the capability and the loader requests the
    # adapter only when a mounted component depends on it.
    if all_rb_sources.includes?("MochiFormat")
      builder_man.register_generated_ruby_source(
        "#{builder_man.pre_tp_dir}/lib/mochi_builtin_format.rb",
        MochiFormatRbFragment.get_ruby_code
      )
    end

    # Array aggregation methods are optional Ruby bytecode. The package graph
    # adds it only for syntactic Array method calls and propagates it through
    # helper-package dependencies.
    builder_man.register_generated_ruby_source(
      "#{builder_man.pre_tp_dir}/lib/mochi_builtin_collections.rb",
      MochiCollectionsRbFragment.get_ruby_code
    )

    builder_man.register_generated_ruby_source(
      "#{builder_man.pre_tp_dir}/lib/mochi_builtin_pointer.rb",
      MochiPointerRbFragment.get_ruby_code
    )
    builder_man.register_generated_ruby_source(
      "#{builder_man.pre_tp_dir}/lib/mochi_builtin_layout.rb",
      MochiLayoutRbFragment.get_ruby_code
    )
    builder_man.register_generated_ruby_source(
      "#{builder_man.pre_tp_dir}/lib/mochi_builtin_shortcuts.rb",
      MochiShortcutsRbFragment.get_ruby_code
    )
    builder_man.register_generated_ruby_source(
      "#{builder_man.pre_tp_dir}/lib/mochi_builtin_drag.rb",
      MochiDragRbFragment.get_ruby_code
    )
    builder_man.register_generated_ruby_source(
      "#{builder_man.pre_tp_dir}/lib/mochi_builtin_files.rb",
      MochiFilesRbFragment.get_ruby_code
    )

    builder_man.register_generated_ruby_source(
      "#{builder_man.pre_tp_dir}/lib/mochi_builtin_json.rb",
      JSONRbFragment.get_ruby_code
    )
    builder_man.register_generated_ruby_source(
      "#{builder_man.pre_tp_dir}/lib/mochi_builtin_time.rb",
      TimeRbFragment.get_ruby_code
    )
    builder_man.register_generated_ruby_source(
      "#{builder_man.pre_tp_dir}/lib/mochi_builtin_download.rb",
      MochiDownloadRbFragment.get_ruby_code
    )

    if prepare_typecheck_tree
      print_separator
      puts "3. Preparing isolated source tree for Sorbet"
      builder_man.copy_ruby_code_base

      print_separator
      puts "4. Packing in Batteries"
      batt_time = Time.measure do
        CoreBattery.generate(builder_man.ruby_src_dir)
      end
      puts "> Batteries took #{batt_time.total_milliseconds.to_i}ms"
    end
  end

  def build(
    input_dir : String,
    output_dir : String,
    with_tc : Bool,
    keep_granular_build_artifacts : Bool,
    capacity_config_path : String? = nil,
    render_target : RenderTarget = RenderTarget::Dom,
  )
    start_time = Time.monotonic.total_nanoseconds.to_u64
    sequence_id = 1_u32
    trace : Pftrace::Trace? = nil
    trace = Pftrace::Trace.new("mochi_build.pftrace") if ENV["MOCHI_BUILD_TRACE"]? == "1"
    builder_man : BuilderMan? = nil
    succeeded = false

    trace.try do |active_trace|
      active_trace.write_clock_snapshot(start_time)
      active_trace.write_process_descriptor(pid: Process.pid.to_i32, name: "MochiBuild", uuid: 100_u64)
      active_trace.write_thread_descriptor(pid: Process.pid.to_i32, tid: Process.pid.to_i32, name: "MainThread", uuid: 101_u64, parent_uuid: 100_u64)
    end

    begin
      # 1. Prepare Input / Output directories
      if input_dir.empty? || output_dir.empty?
        raise "Input & output directory need to be specified"
      end

      capacity_config = capacity_config_path.try { |path| CapacityConfig.read(path) }
      if render_target.desktop?
        raise "The desktop host currently builds on macOS" unless {{ flag?(:darwin) }}
        raise "The desktop target uses the default capacity profile" if capacity_config_path
      elsif capacity_config.nil? || capacity_config.fingerprint == CapacityConfig.default.fingerprint
        InstallationPaths.new.validate_build_resources!
      end
      validate_build_paths(input_dir, output_dir)
      portable_project = PortableProject.read(input_dir)
      if render_target.desktop? && !portable_project
        raise "The desktop target requires #{PortableProject::FILE_NAME}"
      end
      print_separator
      puts "1. input_dir:#{input_dir}, output_dir:#{output_dir}"
      builder_man = BuilderMan.new(input_dir, output_dir)
      bundle_dir = render_target.desktop? ? File.join(builder_man.workspace_dir, "desktop") : output_dir
      prepare_output = render_target.dom? ? -> { prepare_output_dir(bundle_dir) } : nil

      # steps 2-4
      puts "BuildID: #{builder_man.build_id}"
      puts "Working Dir: #{Dir.current}"

      trace_slice(trace, "Setup", sequence_id, "build") do
        setup(builder_man, with_tc)
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
      transpiler = Compiler.new(
        verbose: ENV["MOCHI_VERBOSE_BUILD"]? == "1",
        render_target: render_target,
        capacity_config_path: capacity_config_path,
        portable_project: portable_project
      )
      puts "5. Transpiling Mochi Components"

      mochi_comp_time = Time.measure do
        trace_slice(trace, "Transpiling", sequence_id, "build") do
          transpiler.transpile_directory(
            "#{builder_man.pre_tp_dir}/lib",
            bundle_dir,
            builder_man,
            trace,
            sequence_id,
            builder_man.pre_tp_dir,
            builder_man.input_dir,
            prepare_output
          )
        end
      end
      puts "> Compilation took #{mochi_comp_time.total_milliseconds.to_i}ms"

      print_separator
      if render_target.desktop?
        puts "6. Linking native application"
        paths = InstallationPaths.new
        gvm = paths.gvm_root || raise "Desktop builds need a matching mochi-gvm checkout (MOCHI_GVM_DIR)"
        script = File.join(InstallationPaths::DEVELOPMENT_ROOT, "runtime/desktop/package.rb")
        project = portable_project.not_nil!
        args = [script, gvm, File.expand_path(input_dir), bundle_dir, File.expand_path(output_dir), project.app_id, project.display_name]
        raise "Desktop packaging failed" unless Process.run("ruby", args, output: STDOUT, error: STDERR).success?
      else
        puts "6. Copying Entry Page & Static Assets"
        copy_entry_page(input_dir, output_dir)
        copy_static_assets(input_dir, output_dir)
      end

      if keep_granular_build_artifacts
        puts "Keeping owned build workspace at #{builder_man.workspace_dir}"
      end

      total_ms = (Time.monotonic.total_nanoseconds.to_u64 - start_time) // 1_000_000
      puts "> Total build took #{total_ms}ms"

      print_separator
      puts "Done."
      succeeded = true
    ensure
      trace.try(&.close)
      puts "Trace saved to mochi_build.pftrace" if succeeded && trace
      if active_builder = builder_man
        active_builder.cleanup unless keep_granular_build_artifacts
      end
    end
  end

  private def validate_build_paths(input_dir : String, output_dir : String) : Nil
    input_path = File.expand_path(input_dir)
    raise "Input directory cannot be a symlink: #{input_dir}" if File.symlink?(input_path)
    raise "Input directory does not exist: #{input_dir}" unless Dir.exists?(input_path)
    input_path = File.real_path(input_path)

    output_expanded = File.expand_path(output_dir)
    raise "Build output cannot be a symlink: #{output_dir}" if File.symlink?(output_expanded)
    output_path = BuildPath.canonical(output_expanded)
    raise "Input and output directories must be different" if output_path == input_path
    if BuildPath.within?(input_path, output_path)
      raise "Build output cannot contain the input directory: #{output_dir}"
    end
    if {"lib", "public", "icons"}.any? { |name| BuildPath.within?(output_path, File.join(input_path, name)) }
      raise "Build output cannot be placed inside the input lib/, public/, or icons/ tree: #{output_dir}"
    end
    BuildPath.validate_input_tree(input_path, output_path)
  end

  private def prepare_output_dir(output_dir : String) : Nil
    Dir.mkdir_p(output_dir)
    remove_directory(File.join(output_dir, "components"))
    File.delete(File.join(output_dir, "bundle.js")) if File.exists?(File.join(output_dir, "bundle.js"))
    File.delete(File.join(output_dir, "mochi-manifest.json")) if File.exists?(File.join(output_dir, "mochi-manifest.json"))
  end

  private def copy_entry_page(input_dir : String, output_dir : String)
    return if File.expand_path(input_dir) == File.expand_path(output_dir)
    source = File.join(input_dir, "index.html")
    unless File.file?(source)
      puts "> No index.html in #{input_dir}; skipped"
      return
    end

    FileUtils.cp(source, File.join(output_dir, "index.html"))
    puts "> Copied index.html"
  end

  private def copy_static_assets(input_dir : String, output_dir : String)
    return if File.expand_path(input_dir) == File.expand_path(output_dir)

    public_src = File.join(input_dir, "public")
    if File.directory?(public_src)
      public_dst = File.join(output_dir, "public")
      remove_directory(public_dst) if File.exists?(public_dst)
      FileUtils.cp_r(public_src, public_dst)
      puts "> Copied public/"
    end

    Dir.children(input_dir).each do |entry|
      src_path = File.join(input_dir, entry)
      next unless File.file?(src_path)
      ext = File.extname(entry).downcase
      next unless STATIC_ASSET_EXTS.includes?(ext)
      FileUtils.cp(src_path, File.join(output_dir, entry))
      puts "> Copied #{entry}"
    end
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
