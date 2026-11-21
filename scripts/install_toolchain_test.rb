#!/usr/bin/env ruby
# frozen_string_literal: true

require "tmpdir"
require_relative "toolchain_archive"

def run(*args, chdir:, expected_error: nil, installed: true)
  environment = if installed
    {"PATH" => "/usr/bin:/bin", "HOME" => chdir, "MOCHI_DESKTOP_STORAGE_DIR" => File.join(chdir, "App storage")}
  else
    {}
  end
  output, status = Open3.capture2e(environment, *args, chdir: chdir, unsetenv_others: installed)
  if expected_error
    abort "Expected #{expected_error.inspect} from #{args.first}:\n#{output}" if status.success? || !output.include?(expected_error)
  elsif !status.success?
    abort "Failed #{args.first}:\n#{output}"
  end
  output
end

def snapshot(directory)
  ToolchainArchive.inventory(directory).to_h do |file|
    [file, ToolchainArchive.checksum(File.join(directory, file))]
  end
end

def update_descriptor(path)
  metadata = JSON.parse(File.read(path))
  yield metadata
  File.write(path, JSON.pretty_generate(metadata))
end

def verify_linkage(binary, core: nil)
  ToolchainArchive.command("otool", "-L", binary).lines.drop(1).each do |line|
    load = line.strip.split(/ \(compatibility version /, 2).first
    next if load.start_with?("/usr/lib/", "/System/Library/")
    if core && load.start_with?("@loader_path/")
      resolved = File.expand_path(load.delete_prefix("@loader_path/"), File.dirname(binary))
      next if resolved.start_with?("#{core}/") && File.file?(resolved)
    end
    abort "#{binary} requires a library outside the toolchain: #{load}"
  end
end

checkout = File.expand_path("..", __dir__)
cpu = ToolchainArchive.architecture

Dir.mktmpdir("mochi toolchain test ") do |work|
  archives = File.join(work, "Prebuilt downloads")
  run("ruby", "scripts/package_toolchain.rb", "--desktop", "--output", archives, chdir: checkout, installed: false)
  core_source = File.join(archives, "mochi-macos-#{cpu}.tar.gz")
  desktop_source = File.join(archives, "mochi-desktop-macos-#{cpu}.tar.gz")
  extracted = File.join(work, "Extracted core")
  ToolchainArchive.unpack(core_source, extracted)
  installer = File.join(extracted, "install.rb")
  prefix = File.join(work, "Mochi prefix")
  web_prefix = File.join(work, "Web-only prefix")
  project = File.join(work, "App-only project")
  output = File.join(work, "Desktop output")
  FileUtils.cp_r(File.join(checkout, "e2e/fixtures/clay_inspector"), project)
  update_descriptor(File.join(project, "mochi-portable.json")) do |metadata|
    metadata["display_name"] = "My Stations"
    metadata["app_id"] = "org.mochi.toolchain-fixture"
  end

  run("ruby", installer, "--prefix", prefix, "--desktop", desktop_source, chdir: work)
  web_cli = File.join(web_prefix, "bin/mochi")
  run("ruby", installer, "--prefix", web_prefix, "--toolchain", core_source, chdir: work)
  web_record = JSON.parse(File.read(File.join(web_prefix, "share/mochi/install.json")))
  abort "web-only install contains desktop resources" unless web_record.fetch("targets") == ["dom"] &&
    !File.exist?(File.join(web_record.fetch("toolchain_dir"), "desktop"))

  cli = File.join(prefix, "bin/mochi")
  record_path = File.join(prefix, "share/mochi/install.json")
  record_contents = File.binread(record_path)
  record = JSON.parse(record_contents)
  core = File.dirname(record.fetch("core_toolchain"))
  Dir.glob(File.join(core, "{bin,lib}/*")).sort.each { |binary| verify_linkage(binary, core: core) }
  desktop = record.fetch("desktop_identity")
  unless record.fetch("targets") == %w[dom desktop] && desktop.fetch("architecture") == cpu &&
      desktop.fetch("capacity_fingerprint") == record.fetch("capacity_fingerprint")
    abort "incomplete desktop resource record"
  end
  %w[host replay packager clay_license].each { |key| abort "missing installed #{key}" unless File.file?(desktop.fetch(key)) }

  run(web_cli, "-i", project, "-o", File.join(work, "Web output"), chdir: work)
  web_manifest = File.join(work, "Web output", "mochi-manifest.json")
  abort "DOM output is missing" unless File.file?(web_manifest)

  build = ["--target=desktop", "-i", project, "-o", output]
  run(cli, *build, chdir: work)
  app = File.join(output, "My Stations.app")
  plist = File.join(app, "Contents/Info.plist")
  {"CFBundleIdentifier" => "org.mochi.toolchain-fixture", "CFBundleDisplayName" => "My Stations"}.each do |key, value|
    abort "wrong #{key}" unless run("plutil", "-extract", key, "raw", "-o", "-", plist, chdir: work).strip == value
  end
  linked_host = File.join(app, "Contents/MacOS/Mochi")
  abort "packaging did not use the prelinked host" unless FileUtils.compare_file(linked_host, desktop.fetch("host"))
  verify_linkage(linked_host)
  verify_linkage(desktop.fetch("replay"))
  abort "Clay license is missing" unless File.file?(File.join(app, "Contents/Resources/LICENSE.clay.txt"))
  before = snapshot(app)
  run(web_cli, *build, chdir: work, expected_error: "desktop toolchain is missing")
  run("/usr/bin/env", "MOCHI_DESKTOP_TOOLCHAIN=#{work}/absent", cli, *build,
    chdir: work, expected_error: "MOCHI_DESKTOP_TOOLCHAIN points to missing directory")
  run("/usr/bin/env", "MOCHI_DESKTOP_TOOLCHAIN=#{record.fetch('desktop_toolchain')}", web_cli,
    "--target=desktop", "-i", project, "-o", File.join(work, "Explicit target output"), chdir: work)

  incompatible = File.join(work, "Incompatible target")
  ToolchainArchive.unpack(desktop_source, incompatible)
  descriptor = File.join(incompatible, "desktop.json")
  original = File.binread(descriptor)
  {"native_abi" => 999, "scene_schema" => 999, "capacity_fingerprint" => "0" * 64}.each do |key, value|
    File.binwrite(descriptor, original)
    update_descriptor(descriptor) { |metadata| metadata[key] = value }
    run("/usr/bin/env", "MOCHI_DESKTOP_TOOLCHAIN=#{incompatible}", cli, *build,
      chdir: work, expected_error: "#{descriptor} #{key} mismatch")
  end
  run("ruby", installer, "update", "--prefix", prefix, "--desktop", incompatible, chdir: work,
    expected_error: "capacity_fingerprint mismatch")
  abort "failed update replaced the resource record" unless File.binread(record_path) == record_contents

  File.binwrite(descriptor, original)
  metadata = JSON.parse(original)
  invalid_host = File.join(incompatible, metadata.fetch("paths").fetch("host"))
  File.open(invalid_host, "r+b") do |file|
    file.seek(4)
    other_cpu = ToolchainArchive::MACH_CPUS.keys.find { |key| ToolchainArchive::MACH_CPUS.fetch(key) != cpu }
    file.write([other_cpu].pack("V"))
  end
  update_descriptor(descriptor) do |data|
    data.fetch("files")[metadata.fetch("paths").fetch("host")] = ToolchainArchive.checksum(invalid_host)
  end
  run("/usr/bin/env", "MOCHI_DESKTOP_TOOLCHAIN=#{incompatible}", cli, *build,
    chdir: work, expected_error: "#{invalid_host} has wrong Mach-O architecture")
  abort "failed build changed the executable or app resources" unless before == snapshot(app)

  unrelated = File.join(work, "Unrelated destination", File.basename(app))
  FileUtils.mkdir_p(unrelated)
  sentinel = File.join(unrelated, "Owner data.txt")
  File.write(sentinel, "unrelated")
  run(cli, "--target=desktop", "-i", project, "-o", File.dirname(unrelated),
    chdir: work, expected_error: "Refusing to replace unrelated")
  abort "unrelated output was changed" unless Dir.children(unrelated) == [File.basename(sentinel)] && File.read(sentinel) == "unrelated"

  output = run(cli, "test", "--target=desktop", "-i", project, chdir: work)
  abort "prelinked replay did not run the fixture" unless output.include?("PASS [desktop]")
  run("ruby", installer, "remove", "--prefix", prefix, chdir: work)
  abort "remove retained installed resources" if File.exist?(record.fetch("toolchain_dir"))
  moved = File.join(work, "Moved Stations.app")
  File.rename(app, moved)
  FileUtils.remove_entry(project)
  FileUtils.remove_entry(archives)
  run("sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
    File.join(moved, "Contents/MacOS/Mochi"), "--mochi-verify-app", chdir: work)
  puts "Installed #{cpu} toolchain built and replayed the app. The moved bundle launched with networking denied."
end
