require "file_utils"
require "json"
require "path"
require "random"

class RubyTestRunner
  RECORDER_SOURCE = {{ read_file("#{__DIR__}/../../../runtime/test/mochi_test_recorder.rb") }}
  BROWSER_RUNNER  = {{ read_file("#{__DIR__}/../../../e2e/mochi_test_runner.cjs") }}

  def run(project_path : String) : Int32
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

    workspace = File.join(Dir.tempdir, "mochi-test-#{Random.new.hex(8)}")
    stage_dir = File.join(workspace, "project")
    bundle_dir = File.join(workspace, "bundle")
    plan_path = File.join(workspace, "test-plan.json")
    runner_path = File.join(workspace, "mochi_test_runner.cjs")
    FileUtils.mkdir_p(stage_dir)

    begin
      stage_project(project_root, stage_dir)
      File.write(runner_path, BROWSER_RUNNER)

      status = Process.run(
        command: "ruby",
        args: ["-e", RECORDER_SOURCE, test_dir, plan_path],
        chdir: project_root,
        output: STDOUT,
        error: STDERR
      )
      return status.exit_code unless status.success?

      Dir.cd(workspace) do
        BuildMain.new.build(stage_dir, bundle_dir, false, false)
      end

      File.write(File.join(bundle_dir, "index.html"), <<-HTML)
        <!doctype html>
        <html><head><meta charset="utf-8"><script src="mochi-loader.js"></script></head>
        <body></body></html>
        HTML

      node_modules = File.join(repository_root, "e2e", "node_modules")
      unless File.directory?(node_modules)
        STDERR.puts "mochi test: framework Playwright runner dependencies missing; install Mochi development dependencies"
        return 2
      end
      env = {"NODE_PATH" => node_modules}
      browser_status = Process.run(
        command: "node",
        args: [runner_path, bundle_dir, plan_path],
        chdir: workspace,
        env: env,
        output: STDOUT,
        error: STDERR
      )
      browser_status.exit_code
    rescue ex
      STDERR.puts "mochi test: #{ex.message}"
      1
    ensure
      FileUtils.rm_rf(workspace) if Dir.exists?(workspace)
    end
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

  private def repository_root : String
    File.expand_path(Path[__DIR__, "../../.."].to_s)
  end
end
