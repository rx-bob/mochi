require "file_utils"
require "json"
require "path"
require "random"
require "./installation_paths"
require "../clay/profile"

class RubyTestRunner
  RECORDER_SOURCE = {{ read_file("#{__DIR__}/../../../runtime/test/mochi_test_recorder.rb") }}
  BROWSER_RUNNER  = {{ read_file("#{__DIR__}/../../../e2e/mochi_test_runner.cjs") }}

  def run(project_path : String, browsers = "chromium,firefox,webkit", test_file : String? = nil, target : RenderTarget = RenderTarget::Dom) : Int32
    if target.desktop? && !{{ flag?(:darwin) }}
      STDERR.puts "mochi test: the desktop target requires macOS"
      return 2
    end
    if target.dom?
      selected = browsers == "all" ? %w[chromium firefox webkit] : browsers.split(",").map(&.strip)
      unless !selected.empty? && selected.uniq == selected && (selected - %w[chromium firefox webkit]).empty?
        STDERR.puts "mochi test: unsupported browser selection '#{browsers}'; choose chromium, firefox, webkit, or all"
        return 2
      end
    end
    project_root = File.expand_path(project_path)
    test_dir = File.join(project_root, "test")
    unless File.directory?(File.join(project_root, "lib"))
      STDERR.puts "mochi test: #{project_root} has no lib/ directory"
      return 2
    end
    unless File.directory?(test_dir)
      STDERR.puts "mochi test: no test/ directory in #{project_root}"
      return 2
    end

    if target.dom?
      begin
        paths = InstallationPaths.new
        node_modules = paths.required_test_dependencies!
        paths.validate_test_dependencies!(node_modules)
      rescue ex
        STDERR.puts "mochi test: #{ex.message}"
        return 2
      end
    end

    workspace = File.join(Dir.tempdir, "mochi-test-#{Random.new.hex(8)}")
    stage_dir = File.join(workspace, "project")
    bundle_dir = File.join(workspace, "bundle")
    plan_path = File.join(workspace, "test-plan.json")
    FileUtils.mkdir_p(stage_dir)

    begin
      stage_project(project_root, stage_dir)

      recorder_args = ["-e", RECORDER_SOURCE, test_dir, plan_path]
      recorder_args << test_file if test_file
      status = Process.run(
        command: "ruby",
        args: recorder_args,
        chdir: project_root,
        output: STDOUT,
        error: STDERR
      )
      return status.exit_code unless status.success?

      Dir.cd(workspace) do
        BuildMain.new.build(stage_dir, bundle_dir, false, false, render_target: target)
      end

      if target.desktop?
        run_desktop(workspace, bundle_dir, plan_path)
      else
        run_browser(workspace, bundle_dir, plan_path, selected.not_nil!, node_modules.not_nil!)
      end
    rescue ex
      STDERR.puts "mochi test: #{ex.message}"
      1
    ensure
      FileUtils.rm_rf(workspace) if Dir.exists?(workspace)
    end
  end

  private def run_browser(workspace, bundle_dir, plan_path, browsers, node_modules) : Int32
    runner_path = File.join(workspace, "mochi_test_runner.cjs")
    File.write(runner_path, BROWSER_RUNNER)
    File.write(File.join(bundle_dir, "index.html"), <<-HTML)
      <!doctype html>
      <html><head><meta charset="utf-8"><script src="mochi-loader.js"></script></head>
      <body></body></html>
      HTML

    Process.run(
      command: "node",
      args: [runner_path, bundle_dir, plan_path, browsers.join(",")],
      chdir: workspace,
      env: {"NODE_PATH" => node_modules},
      output: STDOUT,
      error: STDERR
    ).exit_code
  end

  private def run_desktop(workspace, bundle_dir, plan_path) : Int32
    gvm = InstallationPaths.new.gvm_root || raise "Desktop tests need a matching mochi-gvm checkout (MOCHI_GVM_DIR)"
    host = File.join(InstallationPaths::DEVELOPMENT_ROOT, "runtime/desktop")
    runner = File.join(workspace, "mochi-test-desktop")
    status = Process.run(
      File.join(host, "build_host.sh"),
      [gvm, File.join(host, "test/replay.m"), runner],
      output: STDOUT,
      error: STDERR
    )
    return status.exit_code unless status.success?

    resources = File.join(bundle_dir, "Mochi.app/Contents/Resources")
    Process.run(runner, [resources, plan_path], chdir: workspace, output: STDOUT, error: STDERR).exit_code
  end

  private def stage_project(project_root : String, stage_dir : String) : Nil
    %w[lib icons public].each do |name|
      source = File.join(project_root, name)
      next unless Dir.exists?(source)
      FileUtils.cp_r(source, stage_dir)
    end
    Dir.children(project_root).each do |name|
      source = File.join(project_root, name)
      next unless File.file?(source)
      next unless {".css", ".svg", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2"}.includes?(File.extname(name).downcase)
      FileUtils.cp(source, stage_dir)
    end
  end
end
