#!/usr/bin/env ruby
require "fileutils"
require "json"
require "open3"
require "tmpdir"

repo_root = File.expand_path("..", __dir__)
installer = File.join(repo_root, "scripts/install_dev.rb")
temp_root = Dir.mktmpdir("mochi install workflow ")
prefix = File.join(temp_root, "user prefix with spaces")
outside = File.join(temp_root, "unrelated working directory")
fake_mrbc = File.join(temp_root, "fake mrbc")
FileUtils.mkdir_p(outside)
File.write(fake_mrbc, "#!/bin/sh\nexit 0\n")
File.chmod(0o755, fake_mrbc)
env = {"MOCHI_INSTALL_PREFIX" => prefix, "MRBC" => fake_mrbc}
launcher = File.join(prefix, "bin", "mochi")
record_path = File.join(prefix, "share", "mochi", "install.json")

def run(env, *args, chdir:)
  Open3.capture3(env, *args, chdir: chdir)
end

begin
  stdout, stderr, status = run(env, "ruby", installer, "install", chdir: outside)
  raise "install failed: #{stdout}\n#{stderr}" unless status.success?
  raise "launcher missing or not executable" unless File.executable?(launcher)
  record = JSON.parse(File.read(record_path))
  raise "compiler path missing from record" unless File.executable?(record.fetch("compiler"))
  raise "runtime identity missing from record" unless record["runtime_profile"] == "default" && record["gvm_wasm_sha256"]

  stdout, stderr, status = run({}, launcher, "--help", chdir: outside)
  raise "outside-directory launcher failed: #{stdout}\n#{stderr}" unless status.success? && stdout.include?("Usage: mochi")

  project = File.join(temp_root, "project with spaces")
  output = File.join(temp_root, "existing output")
  FileUtils.mkdir_p(File.join(project, "lib"))
  FileUtils.mkdir_p(output)
  sentinel = File.join(output, "keep-on-setup-error")
  File.write(sentinel, "keep")
  File.write(File.join(project, "lib", "Panel.rb"), "class Panel; end\n")
  bad_override = File.join(temp_root, "missing runtime loader.js")
  stdout, stderr, status = run({"MOCHI_LOADER" => bad_override}, launcher, "-i", project, "-o", output, chdir: outside)
  raise "invalid override unexpectedly built: #{stdout}" if status.success?
  raise "override error was not actionable: #{stderr}" unless stderr.include?("MOCHI_LOADER points to missing file")
  raise "build touched output before validating resources" unless File.read(sentinel) == "keep"

  File.write(File.join(prefix, "bin", "user-owned-file"), "keep")
  unicode_loader = File.join(temp_root, "UTF-8 loader.js")
  File.binwrite(unicode_loader, File.binread(record.fetch("loader")) + "\n// Café\n".b)
  stdout, stderr, status = run(env.merge("LC_ALL" => "C", "MOCHI_LOADER" => unicode_loader),
    "ruby", installer, "update", chdir: outside)
  raise "update failed: #{stdout}\n#{stderr}" unless status.success?
  raise "loader override missing from record" unless JSON.parse(File.read(record_path)).fetch("loader") == unicode_loader
  stdout, stderr, status = run(env, "ruby", installer, "remove", chdir: outside)
  raise "remove failed: #{stdout}\n#{stderr}" unless status.success?
  raise "owned launcher was not removed" if File.exist?(launcher)
  raise "owned record was not removed" if File.exist?(record_path)
  raise "unowned file was removed" unless File.exist?(File.join(prefix, "bin", "user-owned-file"))

  unrelated_prefix = File.join(temp_root, "unrelated install")
  unrelated_launcher = File.join(unrelated_prefix, "bin", "mochi")
  FileUtils.mkdir_p(File.dirname(unrelated_launcher))
  File.write(unrelated_launcher, "unrelated executable")
  stdout, stderr, status = run(
    {"MOCHI_INSTALL_PREFIX" => unrelated_prefix, "MRBC" => fake_mrbc},
    "ruby", installer, "install", chdir: outside
  )
  raise "installer overwrote unrelated launcher" if status.success? || File.read(unrelated_launcher) != "unrelated executable"
  puts "development install workflow passed"
ensure
  FileUtils.remove_entry(temp_root) if File.directory?(temp_root)
end
