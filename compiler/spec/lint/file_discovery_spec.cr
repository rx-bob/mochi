require "spec"
require "file_utils"
require "random"
require "../../src/lint/file_discovery"

module LintFileDiscoverySpecSupport
  extend self

  def with_tree(prefix = "mochi_lint_discovery", &)
    root = File.join(Dir.tempdir, "#{prefix}_#{Random.new.hex(8)}")
    Dir.mkdir_p(root)
    yield root
  ensure
    FileUtils.rm_rf(root) if root
  end

  def write(root : String, relative_path : String, content : String = "class Widget\nend\n") : String
    path = File.join(root, relative_path)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def config(root : String, yaml : String, project : String = root, explicit : Bool = true) : Lint::Config
    write(root, ".mochi-lint.yml", yaml)
    Lint::Config.load(File.realpath(project), explicit, nil, root)
  end
end

describe Lint::FileDiscovery do
  it "discovers included Ruby files in deterministic order and deduplicates overlapping globs" do
    LintFileDiscoverySpecSupport.with_tree do |root|
      LintFileDiscoverySpecSupport.write(root, "lib/z_last.rb")
      LintFileDiscoverySpecSupport.write(root, "lib/a_first.rb")
      LintFileDiscoverySpecSupport.write(root, "lib/nested/middle.rb")
      LintFileDiscoverySpecSupport.write(root, "lib/notes.txt")
      config = LintFileDiscoverySpecSupport.config(root, <<-YAML)
        version: 1
        include:
          - "**/*.rb"
          - "lib/**/*.rb"
        YAML

      files = Lint::FileDiscovery.discover(config.project_root, config)

      files.map(&.relative_path).should eq ["lib/a_first.rb", "lib/nested/middle.rb", "lib/z_last.rb"]
      files.map(&.absolute_path).should eq files.map(&.absolute_path).sort
    end
  end

  it "applies excludes after includes" do
    LintFileDiscoverySpecSupport.with_tree do |root|
      LintFileDiscoverySpecSupport.write(root, "lib/keep.rb")
      LintFileDiscoverySpecSupport.write(root, "lib/generated/drop.rb")
      LintFileDiscoverySpecSupport.write(root, "lib/generated/nested/drop.rb")
      config = LintFileDiscoverySpecSupport.config(root, <<-YAML)
        version: 1
        include: ["lib/**/*.rb"]
        exclude: ["lib/generated/**"]
        YAML

      files = Lint::FileDiscovery.discover(config.project_root, config)

      files.map(&.relative_path).should eq ["lib/keep.rb"]
    end
  end

  it "prunes generated and version-control directories by name" do
    LintFileDiscoverySpecSupport.with_tree do |root|
      LintFileDiscoverySpecSupport.write(root, "lib/keep.rb")
      Lint::Config::PRUNED_DIRECTORIES.each do |name|
        LintFileDiscoverySpecSupport.write(root, "#{name}/nested/drop.rb")
      end
      config = LintFileDiscoverySpecSupport.config(root, <<-YAML)
        version: 1
        include: ["**/*.rb"]
        YAML

      files = Lint::FileDiscovery.discover(config.project_root, config)

      files.map(&.relative_path).should eq ["lib/keep.rb"]
    end
  end

  it "skips public assets and non-Ruby files even with a broad include" do
    LintFileDiscoverySpecSupport.with_tree do |root|
      LintFileDiscoverySpecSupport.write(root, "lib/keep.rb")
      LintFileDiscoverySpecSupport.write(root, "public/drop.rb")
      LintFileDiscoverySpecSupport.write(root, "styles/drop.css", "body {}\n")
      LintFileDiscoverySpecSupport.write(root, "lib/theme.css", "body {}\n")
      config = LintFileDiscoverySpecSupport.config(root, <<-YAML)
        version: 1
        include: ["**/*.rb"]
        YAML

      files = Lint::FileDiscovery.discover(config.project_root, config)

      files.map(&.relative_path).should eq ["lib/keep.rb"]
    end
  end

  it "skips file, directory, and cyclic symlinks without escaping the project" do
    LintFileDiscoverySpecSupport.with_tree do |root|
      LintFileDiscoverySpecSupport.write(root, "lib/keep.rb")
      LintFileDiscoverySpecSupport.write(root, "outside/drop.rb")
      File.symlink(File.join(root, "lib", "keep.rb"), File.join(root, "lib", "file_link.rb"))
      File.symlink(File.join(root, "outside"), File.join(root, "lib", "dir_link"))
      File.symlink(File.join(root, "lib"), File.join(root, "lib", "cycle"))
      config = LintFileDiscoverySpecSupport.config(root, <<-YAML)
        version: 1
        include: ["lib/**/*.rb"]
        YAML

      files = Lint::FileDiscovery.discover(config.project_root, config)

      files.map(&.relative_path).should eq ["lib/keep.rb"]
    end
  end

  it "intersects config globs with an explicit project boundary" do
    LintFileDiscoverySpecSupport.with_tree do |root|
      config_path = LintFileDiscoverySpecSupport.write(root, ".mochi-lint.yml", <<-YAML)
        version: 1
        include: ["app/lib/**/*.rb"]
        YAML
      LintFileDiscoverySpecSupport.write(root, "app/lib/inside.rb")
      LintFileDiscoverySpecSupport.write(root, "app/src/outside.rb")
      LintFileDiscoverySpecSupport.write(root, "other/lib/outside.rb")
      project = File.join(root, "app")
      config = Lint::Config.load(File.realpath(project), true, config_path, root)

      files = Lint::FileDiscovery.discover(config.project_root, config)

      files.map(&.relative_path).should eq ["lib/inside.rb"]
    end
  end

  it "reports config-relative matches under a project that contains the config" do
    LintFileDiscoverySpecSupport.with_tree do |root|
      config_path = LintFileDiscoverySpecSupport.write(root, "apps/app/.mochi-lint.yml", <<-YAML)
        version: 1
        include: ["lib/**/*.rb"]
        YAML
      LintFileDiscoverySpecSupport.write(root, "apps/app/lib/inside.rb")
      LintFileDiscoverySpecSupport.write(root, "apps/app/other/outside.rb")
      config = Lint::Config.load(File.realpath(root), true, config_path, root)

      files = Lint::FileDiscovery.discover(config.project_root, config)

      files.map(&.relative_path).should eq ["apps/app/lib/inside.rb"]
    end
  end

  it "returns an empty selection when no source matches" do
    LintFileDiscoverySpecSupport.with_tree do |root|
      LintFileDiscoverySpecSupport.write(root, "lib/notes.txt")
      config = LintFileDiscoverySpecSupport.config(root, <<-YAML)
        version: 1
        include: ["lib/**/*.rb"]
        exclude: ["lib/**"]
        YAML

      Lint::FileDiscovery.discover(config.project_root, config).should be_empty
    end
  end
end
