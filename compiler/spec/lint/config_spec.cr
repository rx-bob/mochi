require "spec"
require "file_utils"
require "random"
require "../../src/lint/config"

module LintConfigSpecSupport
  extend self

  def with_tree(prefix = "mochi_lint_config", &)
    root = File.join(Dir.tempdir, "#{prefix}_#{Random.new.hex(8)}")
    Dir.mkdir_p(root)
    yield root
  ensure
    FileUtils.rm_rf(root) if root
  end

  def write(root : String, relative_path : String, content : String) : String
    path = File.join(root, relative_path)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def load(root : String, explicit : Bool = true, config : String? = nil, working_directory : String = root) : Lint::Config
    Lint::Config.load(File.realpath(root), explicit, config, working_directory)
  end

  def expect_error(message : String, &) : Lint::ConfigError
    error = expect_raises(Lint::ConfigError) { yield }
    error.message.to_s.should contain(message)
    error
  end
end

describe Lint::Config do
  it "loads the documented example with rule levels and options" do
    LintConfigSpecSupport.with_tree do |root|
      LintConfigSpecSupport.write(root, ".mochi-lint.yml", <<-YAML)
        version: 1
        include: ["lib/**/*.rb"]
        exclude: ["lib/generated/**"]
        rules:
          correctness/unknown-handler: error
          components/prop-write: warning
          metrics/method-length:
            severity: warning
            max: 60
          migration/css-timer: off
        YAML

      config = LintConfigSpecSupport.load(root)

      config.path.should eq File.realpath(File.join(root, ".mochi-lint.yml"))
      config.root.should eq File.realpath(root)
      config.project_root.should eq File.realpath(root)
      config.include_globs.should eq ["lib/**/*.rb"]
      config.exclude_globs.should eq ["lib/generated/**"]
      config.level_for("correctness/unknown-handler").should eq Lint::RuleLevel::Error
      config.level_for("components/prop-write").should eq Lint::RuleLevel::Warning
      config.settings_for("metrics/method-length")["max"].should eq 60
      config.enabled?("migration/css-timer").should be_false
      config.enabled?("templates/unstable-key").should be_false
    end
  end

  it "uses built-in defaults rooted at the project when no config exists" do
    LintConfigSpecSupport.with_tree do |root|
      Dir.mkdir_p(File.join(root, "lib"))

      config = LintConfigSpecSupport.load(root)

      config.path.should be_nil
      config.root.should eq File.realpath(root)
      config.project_root.should eq File.realpath(root)
      config.include_globs.should eq ["lib/**/*.rb"]
      config.exclude_globs.should be_empty
      config.level_for("correctness/unknown-handler").should eq Lint::RuleLevel::Error
      config.level_for("components/prop-write").should eq Lint::RuleLevel::Warning
      config.enabled?("templates/unstable-key").should be_false
      config.enabled?("money/float-to-minor-units").should be_false
    end
  end

  it "discovers the nearest config upward from a nested working directory" do
    LintConfigSpecSupport.with_tree do |root|
      LintConfigSpecSupport.write(root, ".mochi-lint.yml", <<-YAML)
        version: 1
        rules:
          components/prop-write: error
        YAML
      nested = File.join(root, "lib", "nested")
      Dir.mkdir_p(nested)

      config = LintConfigSpecSupport.load(nested, false, nil, nested)

      config.path.should eq File.realpath(File.join(root, ".mochi-lint.yml"))
      config.root.should eq File.realpath(root)
      config.project_root.should eq File.realpath(root)
      config.level_for("components/prop-write").should eq Lint::RuleLevel::Error
    end
  end

  it "stops discovery at the nearest repository boundary" do
    LintConfigSpecSupport.with_tree do |root|
      LintConfigSpecSupport.write(root, ".mochi-lint.yml", "version: 2\n")
      repo = File.join(root, "repo")
      Dir.mkdir_p(File.join(repo, ".git"))
      app = File.join(repo, "app")
      Dir.mkdir_p(app)

      config = LintConfigSpecSupport.load(app, false, nil, app)

      config.path.should be_nil
      config.root.should eq File.realpath(app)
      config.project_root.should eq File.realpath(app)
      config.include_globs.should eq ["lib/**/*.rb"]
    end
  end

  it "uses an explicit config without falling back when the path is invalid" do
    LintConfigSpecSupport.with_tree do |root|
      LintConfigSpecSupport.write(root, ".mochi-lint.yml", "version: 1\n")
      missing = File.join(root, "missing.yml")

      error = LintConfigSpecSupport.expect_error("config file not found") do
        LintConfigSpecSupport.load(root, false, missing)
      end
      error.path.should eq missing

      directory = File.join(root, "config-dir")
      Dir.mkdir_p(directory)
      LintConfigSpecSupport.expect_error("config path is not a file") do
        LintConfigSpecSupport.load(root, false, directory)
      end
    end
  end

  it "makes the config directory the project root when no -i is supplied" do
    LintConfigSpecSupport.with_tree do |root|
      config_dir = File.join(root, "config")
      LintConfigSpecSupport.write(root, "config/.mochi-lint.yml", "version: 1\n")

      config = LintConfigSpecSupport.load(config_dir, false, nil, config_dir)

      config.root.should eq File.realpath(File.join(root, "config"))
      config.project_root.should eq File.realpath(File.join(root, "config"))
    end
  end

  it "accepts an explicit -i project inside the config directory" do
    LintConfigSpecSupport.with_tree do |root|
      LintConfigSpecSupport.write(root, ".mochi-lint.yml", <<-YAML)
        version: 1
        include: ["app/lib/**/*.rb"]
        YAML
      project = File.join(root, "app")
      Dir.mkdir_p(File.join(project, "lib"))

      config = LintConfigSpecSupport.load(project, true, nil, root)

      config.root.should eq File.realpath(root)
      config.project_root.should eq File.realpath(project)
      config.include_globs.should eq ["app/lib/**/*.rb"]
    end
  end

  it "rejects a config directory that neither contains nor lives inside the project" do
    LintConfigSpecSupport.with_tree do |root|
      config_path = LintConfigSpecSupport.write(root, "other/.mochi-lint.yml", "version: 1\n")
      project = File.join(root, "project")
      Dir.mkdir_p(project)

      error = LintConfigSpecSupport.expect_error("is not compatible with project") do
        LintConfigSpecSupport.load(project, true, config_path, root)
      end
      error.path.should eq File.realpath(config_path)
    end
  end

  it "rejects duplicate keys at every config level" do
    LintConfigSpecSupport.with_tree do |root|
      cases = {
        "version: 1\nversion: 1\n"                                                                   => "duplicate key 'version'",
        "version: 1\nrules:\n  components/prop-write: warning\n  components/prop-write: error\n"     => "duplicate key 'components/prop-write'",
        "version: 1\nrules:\n  metrics/method-length:\n    severity: warning\n    severity: error\n" => "duplicate key 'severity'",
      }

      cases.each do |content, message|
        LintConfigSpecSupport.write(root, ".mochi-lint.yml", content)
        LintConfigSpecSupport.expect_error(message) { LintConfigSpecSupport.load(root) }
      end
    end
  end

  it "rejects unsupported schema versions and required-key omissions" do
    LintConfigSpecSupport.with_tree do |root|
      {
        "version: 2\n"                       => "unsupported config version '2'",
        "include: [\"lib/**/*.rb\"]\n"       => "missing required key 'version'",
        "\n"                                 => "config must contain exactly one YAML document",
        "---\nversion: 1\n---\nversion: 1\n" => "config must contain exactly one YAML document",
      }.each do |content, message|
        LintConfigSpecSupport.write(root, ".mochi-lint.yml", content)
        LintConfigSpecSupport.expect_error(message) { LintConfigSpecSupport.load(root) }
      end
    end
  end

  it "rejects wrong types and quoted schema or threshold values" do
    LintConfigSpecSupport.with_tree do |root|
      {
        "version: \"1\"\n"                                                                       => "version must be the integer 1",
        "version: 1\ninclude: \"lib/**/*.rb\"\n"                                                 => "include must be a sequence",
        "version: 1\nrules: []\n"                                                                => "rules must be a mapping",
        "version: 1\nrules:\n  components/prop-write: []\n"                                      => "rule 'components/prop-write' must be a mapping",
        "version: 1\nrules:\n  metrics/method-length:\n    severity: warning\n    max: \"60\"\n" => "must be a positive integer",
      }.each do |content, message|
        LintConfigSpecSupport.write(root, ".mochi-lint.yml", content)
        LintConfigSpecSupport.expect_error(message) { LintConfigSpecSupport.load(root) }
      end
    end
  end

  it "rejects unknown rules, options, severities, and non-configurable rules" do
    LintConfigSpecSupport.with_tree do |root|
      {
        "version: 1\nrules:\n  unknown/rule: warning\n"                                         => "unknown rule 'unknown/rule'",
        "version: 1\nrules:\n  metrics/method-length:\n    severity: warning\n    minimum: 3\n" => "unknown option 'minimum'",
        "version: 1\nrules:\n  components/prop-write: fatal\n"                                  => "invalid severity 'fatal'",
        "version: 1\nrules:\n  ruby/syntax: warning\n"                                          => "always enabled and cannot be configured",
      }.each do |content, message|
        LintConfigSpecSupport.write(root, ".mochi-lint.yml", content)
        LintConfigSpecSupport.expect_error(message) { LintConfigSpecSupport.load(root) }
      end
    end
  end

  it "rejects nonpositive and malformed option values" do
    LintConfigSpecSupport.with_tree do |root|
      {
        "max: 0\n"    => "must be a positive integer",
        "max: -1\n"   => "must be a positive integer",
        "max: 1.5\n"  => "must be a positive integer",
        "max: nope\n" => "must be a positive integer",
      }.each do |option, message|
        content = "version: 1\nrules:\n  metrics/method-length:\n    severity: warning\n    #{option}"
        LintConfigSpecSupport.write(root, ".mochi-lint.yml", content)
        LintConfigSpecSupport.expect_error(message) { LintConfigSpecSupport.load(root) }
      end
    end
  end

  it "rejects malformed, absolute, empty, and escaping globs" do
    LintConfigSpecSupport.with_tree do |root|
      ["lib/[", "../lib/**/*.rb", "/lib/**/*.rb", ""].each do |glob|
        content = "version: 1\ninclude:\n  - #{glob.inspect}\n"
        LintConfigSpecSupport.write(root, ".mochi-lint.yml", content)
        LintConfigSpecSupport.expect_error("glob") { LintConfigSpecSupport.load(root) }
      end
    end
  end

  it "reports config errors with the config path and source location" do
    LintConfigSpecSupport.with_tree do |root|
      path = LintConfigSpecSupport.write(root, ".mochi-lint.yml", <<-YAML)
        version: 1
        rules:
          unknown/rule: warning
        YAML

      error = LintConfigSpecSupport.expect_error("unknown rule 'unknown/rule'") do
        LintConfigSpecSupport.load(root)
      end

      error.path.should eq File.realpath(path)
      error.line.should_not be_nil
      error.column.should_not be_nil
      error.location.should match(/\A#{Regex.escape(File.realpath(path))}:\d+:\d+\z/)
    end
  end
end
