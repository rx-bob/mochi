require "spec"
require "file_utils"
require "random"

require "../../src/lint/config"
require "../../src/lint/file_discovery"
require "../../src/lint/project_index"
require "../../src/lint/suppressions"
require "../../src/lint/rules/package_files"
require "../../src/tooling/lint_runner"

module LintPackageFilesSpecSupport
  extend self

  def with_project(prefix = "mochi_lint_package_files", &)
    root = File.join(Dir.tempdir, "#{prefix}_#{Random.new.hex(8)}")
    Dir.mkdir_p(File.join(root, "lib"))
    yield root
  ensure
    FileUtils.rm_rf(root) if root
  end

  def write(root : String, relative_path : String, source : String) : String
    path = File.join(root, relative_path)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, source)
    path
  end

  def config(root : String, rules : Hash(String, String)? = nil) : Lint::Config
    yaml = String.build do |io|
      io << "version: 1\n"
      io << "include:\n  - \"lib/**/*.rb\"\n"
      if rules
        io << "rules:\n"
        rules.each { |rule, value| io << "  #{rule}: #{value}\n" }
      end
    end
    write(root, ".mochi-lint.yml", yaml)
    Lint::Config.load(root, true, nil, root)
  end

  def diagnostics(root : String, rules : Hash(String, String)? = nil) : Array(Lint::Diagnostic)
    lint_config = config(root, rules)
    files = Lint::FileDiscovery.discover(lint_config.project_root, lint_config)
    index = Lint::ProjectIndex.build(files, lint_config)
    begin
      raw = Lint::Rules::PackageFiles.diagnostics(index)
      Lint::Suppressions.apply(index, raw)
    ensure
      index.close
    end
  end

  def run_lint(root : String, args = [] of String) : Tuple(Int32, String, String)
    output = IO::Memory.new
    error = IO::Memory.new
    status = LintRunner.new.run(["-i", root] + args, output, error)
    {status, output.to_s, error.to_s}
  end

  def write_package(root : String, directory : String, count : Int32, prefix = "File") : Nil
    count.times do |index|
      name = "#{prefix}#{index.to_s.rjust(2, '0')}"
      write(root, File.join(directory, "#{name}.rb"), "class #{name}\nend\n")
    end
  end
end

describe Lint::Rules::PackageFiles do
  it "passes exactly 10 Ruby files and reports 11" do
    LintPackageFilesSpecSupport.with_project do |root|
      LintPackageFilesSpecSupport.write_package(root, "lib/widgets", 10)
      LintPackageFilesSpecSupport.diagnostics(root).should be_empty

      LintPackageFilesSpecSupport.write(
        root,
        "lib/widgets/File10.rb",
        "class File10\nend\n",
      )
      diagnostics = LintPackageFilesSpecSupport.diagnostics(root)
      diagnostics.size.should eq 1
      diagnostic = diagnostics.first
      diagnostic.severity.should eq Lint::Severity::Warning
      diagnostic.rule.should eq Lint::Rules::PackageFiles::RULE
      diagnostic.path.should eq "lib/widgets/File00.rb"
      diagnostic.start_line.should eq 1
      diagnostic.message.should eq "package 'lib/widgets' has 11 Ruby files; maximum is 10"
      diagnostic.suggestion.should eq "Split the package into subdirectories with at most 10 Ruby files each."
    end
  end

  it "counts immediate Ruby files only, keeping subdirectories separate" do
    LintPackageFilesSpecSupport.with_project do |root|
      LintPackageFilesSpecSupport.write_package(root, "lib/widgets", 7, "Main")
      LintPackageFilesSpecSupport.write_package(root, "lib/widgets/forms", 7, "Form")
      4.times do |index|
        LintPackageFilesSpecSupport.write(root, "lib/widgets/theme_#{index}.css", "/* theme */\n")
      end

      LintPackageFilesSpecSupport.diagnostics(root).should be_empty
    end
  end

  it "uses the configured maximum, can be disabled, and can be suppressed" do
    LintPackageFilesSpecSupport.with_project do |root|
      LintPackageFilesSpecSupport.write_package(root, "lib/widgets", 3)

      rules = {"structure/package-files" => "{severity: warning, max: 3}"}
      LintPackageFilesSpecSupport.diagnostics(root, rules).should be_empty

      rules = {"structure/package-files" => "{severity: warning, max: 2}"}
      diagnostics = LintPackageFilesSpecSupport.diagnostics(root, rules)
      diagnostics.size.should eq 1
      diagnostics.first.message.should eq "package 'lib/widgets' has 3 Ruby files; maximum is 2"

      rules = {"structure/package-files" => "off"}
      LintPackageFilesSpecSupport.diagnostics(root, rules).should be_empty

      LintPackageFilesSpecSupport.write(
        root,
        "lib/widgets/File00.rb",
        "# mochi-lint: disable-next structure/package-files -- generated package layout\nclass File00\nend\n",
      )
      rules = {"structure/package-files" => "{severity: warning, max: 2}"}
      LintPackageFilesSpecSupport.diagnostics(root, rules).should be_empty
    end
  end

  it "fails the CLI by default and passes when disabled" do
    LintPackageFilesSpecSupport.with_project do |root|
      LintPackageFilesSpecSupport.write_package(root, "lib/widgets", 11)

      status, output, error = LintPackageFilesSpecSupport.run_lint(root)
      status.should eq 1
      output.should contain "lib/widgets/File00.rb:1:1: warning structure/package-files: package 'lib/widgets' has 11 Ruby files; maximum is 10"
      error.should be_empty

      LintPackageFilesSpecSupport.config(root, {"structure/package-files" => "off"})
      status, output, error = LintPackageFilesSpecSupport.run_lint(root)
      status.should eq 0
      output.should be_empty
      error.should be_empty
    end
  end
end
