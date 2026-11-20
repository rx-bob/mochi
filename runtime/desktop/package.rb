# frozen_string_literal: true
require "fileutils"
require "tmpdir"
require "json"
require "open3"

gvm, project, compiled, output, app_id, display_name = ARGV
abort "macOS AppKit is required to build a desktop application" unless RUBY_PLATFORM.include?("darwin")
scene = JSON.parse(File.read(File.join(compiled, "scene.json")))
product = File.join(output, "Mochi.app")
FileUtils.mkdir_p(output)

def checked(*command)
  system(*command, exception: true)
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
      checked("woff2_decompress", temp)
      source = File.join(work, "#{id}.ttf")
    end
    name = "#{id}#{File.extname(source)}"
    FileUtils.cp(source, File.join(resources, name))
    [id, name]
  end
  scene.delete("font_licenses").each_with_index do |license, index|
    FileUtils.cp(File.join(project, license), File.join(resources, "#{index}-#{File.basename(license)}"))
  end
  FileUtils.cp(File.expand_path("../clay/LICENSE.clay.txt", __dir__), resources)
  File.write(File.join(resources, "scene.json"), JSON.generate(scene))
  plist = File.join(app, "Contents", "Info.plist")
  File.write(plist, JSON.generate({
    CFBundleIdentifier: app_id, CFBundleExecutable: "Mochi", CFBundlePackageType: "APPL",
    CFBundleName: display_name, CFBundleVersion: "1", NSHighResolutionCapable: true,
    MochiDesktopProduct: "1"
  }))
  checked("plutil", "-convert", "xml1", plist)
  checked(File.join(__dir__, "build_host.sh"), gvm, File.join(__dir__, "main.m"), File.join(bin, "Mochi"))
  checked("codesign", "--force", "--sign", "-", app)

  File.open(output) do |dir|
    dir.flock(File::LOCK_EX)
    abort "Refusing to replace symlink #{product}" if File.symlink?(product)
    if File.exist?(product)
      mark, status = Open3.capture2("plutil", "-extract", "MochiDesktopProduct", "raw", "-o", "-",
                                     File.join(product, "Contents", "Info.plist"))
      abort "Refusing to replace unrelated #{product}" unless status.success? && mark.strip == "1"
      previous = File.join(work, "previous.app")
      File.rename(product, previous)
    end
    begin
      File.rename(app, product)
    rescue
      File.rename(previous, product) if previous
      raise
    end
  end
end
puts "Built #{product}"
