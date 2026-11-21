# frozen_string_literal: true
require "fileutils"
require "fiddle"
require "tmpdir"
require "json"
require "open3"

gvm, host, clay_license, archive_root, decoder, project, compiled, output, app_id, display_name, bundle_name, *notices = ARGV
abort "macOS AppKit is required to build a desktop application" unless RUBY_PLATFORM.include?("darwin")
scene = JSON.parse(File.read(File.join(compiled, "scene.json")))
abort "invalid desktop bundle name" unless File.basename(bundle_name) == bundle_name &&
  bundle_name.end_with?(".app") && !bundle_name.start_with?(".")
abort "desktop scene app identity does not match #{app_id}" unless scene.fetch("app_id") == app_id
product = File.join(output, bundle_name)
FileUtils.mkdir_p(output)

def checked(*command)
  system(*command, exception: true)
end

def replace_app(staged, product)
  # Darwin exchanges the two directory entries in one operation. The old
  # product stays at its published path even if the exchange fails.
  rename = Fiddle::Function.new(Fiddle::Handle::DEFAULT["renamex_np"],
    [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
  rename_swap = 0x00000002
  return if rename.call(staged, product, rename_swap).zero?
  raise SystemCallError.new("Could not replace #{product}", Fiddle.last_error)
end

Dir.mktmpdir(".mochi-desktop-", output) do |work|
  app = File.join(work, "Mochi.app")
  resources = File.join(app, "Contents", "Resources")
  bin = File.join(app, "Contents", "MacOS")
  FileUtils.mkdir_p([resources, bin])
  scene["packages"].each do |name|
    FileUtils.cp(File.join(compiled, "components", name), File.join(resources, name))
  end

  scene["fonts"] = scene.delete("font_assets").to_h do |id, face|
    source = File.join(project, face.fetch("file"))
    if File.extname(source) == ".woff2"
      temp = File.join(work, "#{id}.woff2")
      FileUtils.cp(source, temp)
      checked(decoder, temp)
      source = File.join(work, "#{id}.ttf")
    end
    name = "#{id}#{File.extname(source)}"
    FileUtils.cp(source, File.join(resources, name))
    [id, name]
  end
  scene.delete("font_licenses").each_with_index do |license, index|
    FileUtils.cp(File.join(project, license), File.join(resources, "#{index}-#{File.basename(license)}"))
  end
  FileUtils.cp(clay_license, File.join(resources, "LICENSE.clay.txt"))
  notices.each do |path|
    destination = File.join(resources, "ToolchainLicenses", path.delete_prefix("licenses/"))
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(archive_root, path), destination)
  end
  File.write(File.join(resources, "scene.json"), JSON.generate(scene))
  plist = File.join(app, "Contents", "Info.plist")
  File.write(plist, JSON.generate({
    CFBundleIdentifier: app_id, CFBundleExecutable: "Mochi", CFBundlePackageType: "APPL",
    CFBundleName: display_name, CFBundleDisplayName: display_name, CFBundleVersion: "1", NSHighResolutionCapable: true,
    MochiDesktopProduct: "1"
  }))
  checked("plutil", "-convert", "xml1", plist)
  executable = File.join(bin, "Mochi")
  if host.empty?
    checked(File.join(__dir__, "build_host.sh"), gvm, File.join(__dir__, "main.m"), executable)
  else
    FileUtils.cp(host, executable, preserve: true)
  end

  File.open(output) do |dir|
    dir.flock(File::LOCK_EX)
    abort "Refusing to replace symlink #{product}" if File.symlink?(product)
    if File.exist?(product)
      previous_plist = File.join(product, "Contents", "Info.plist")
      metadata, status = Open3.capture2e("plutil", "-convert", "json", "-o", "-", previous_plist)
      installed = status.success? ? JSON.parse(metadata, create_additions: false) : {}
      abort "Refusing to replace unrelated #{product}" unless installed["MochiDesktopProduct"] == "1" &&
        installed["CFBundleIdentifier"] == app_id
      replace_app(app, product)
    else
      File.rename(app, product)
    end
  end
end
puts "Built #{product}"
