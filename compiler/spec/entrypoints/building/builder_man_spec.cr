require "spec"
require "file_utils"
require "random"
require "../../../src/entrypoints/building/builder_man"

describe BuilderMan do
  it "uses unique owned workspaces and copies literal paths without touching output" do
    root = File.join(Dir.tempdir, "mochi workspace ; literal #{Random.new.hex(6)}")
    input = File.join(root, "input with spaces;$(touch #{root}/injected)")
    output = File.join(input, "build")
    Dir.mkdir_p(File.join(input, "lib"))
    Dir.mkdir_p(output)
    File.write(File.join(input, "lib", "counter ; literal.rb"), "class Counter; end")
    File.write(File.join(output, "sentinel.txt"), "owned by caller")

    first = BuilderMan.new(input, output)
    second = BuilderMan.new(input, output)
    begin
      first.workspace_dir.should_not eq(second.workspace_dir)
      first.copy_ruby_code_to_pre_tp

      staged = File.join(first.pre_tp_dir, "lib", "counter ; literal.rb")
      File.read(staged).should eq("class Counter; end")
      File.exists?(File.join(first.pre_tp_dir, "build")).should be_false
      File.read(File.join(output, "sentinel.txt")).should eq("owned by caller")
      File.exists?(File.join(root, "injected")).should be_false

      first.cleanup
      first.cleanup
      File.exists?(first.workspace_dir).should be_false
      File.exists?(second.workspace_dir).should be_true
    ensure
      first.cleanup
      second.cleanup
      FileUtils.rm_rf(root)
    end
  end

  it "rejects symlinks in the source tree before copying them" do
    root = File.join(Dir.tempdir, "mochi_symlink_input_#{Random.new.hex(6)}")
    input = File.join(root, "input")
    Dir.mkdir_p(File.join(input, "lib"))
    File.write(File.join(root, "outside.rb"), "class Outside; end")
    File.symlink(File.join(root, "outside.rb"), File.join(input, "lib", "outside.rb"))

    manager = BuilderMan.new(input)
    begin
      error = expect_raises(Exception) { manager.copy_ruby_code_to_pre_tp }
      error.message.to_s.should contain("contains a symlink")
    ensure
      manager.cleanup
      FileUtils.rm_rf(root)
    end
  end
end
