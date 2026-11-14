require "spec"
require "file_utils"
require "random"
require "../src/initializer"

describe Initializer do
  it "scaffolds a GVM app with a Ruby behavior test command and example" do
    root = File.join(Dir.tempdir, "mochi_initializer_#{Random.rand(1_000_000)}")
    Dir.mkdir_p(root)

    begin
      Dir.cd(root) do
        Initializer.new("sample")
      end

      project = File.join(root, "sample")
      taskfile = File.read(File.join(project, "Taskfile.yml"))
      index = File.read(File.join(project, "index.html"))
      readme = File.read(File.join(project, "README.md"))
      example = File.read(File.join(project, "test", "counter_test.rb"))

      taskfile.should contain("mochi test -i")
      taskfile.should contain("mochi dev --config")
      index.should contain("mochi-loader.js")
      index.should contain(%(data-mochi-manifest="./mochi-manifest.json"))
      index.should contain(%(<base href="/">))
      index.should contain("<my-counter></my-counter>")
      index.should_not contain("https://github.com/")
      index.should_not contain("Opal")
      readme.should contain("test/")
      readme.should contain("assert_text")
      readme.should contain(".chi")
      readme.should contain(">>>")
      readme.should contain("npx playwright install")
      readme.should contain("No app-authored JavaScript is needed")
      example.should contain("Mochi::Test.test")
      example.should contain("assert_text")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
