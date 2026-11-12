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
      index.should contain("mochi-loader.js")
      index.should_not contain("Opal")
      readme.should contain("test/")
      readme.should contain("assert_text")
      readme.should contain(".chi")
      readme.should contain(">>>")
      example.should contain("Mochi::Test.test")
      example.should contain("assert_text")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
