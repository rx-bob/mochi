# frozen_string_literal: true
require "fileutils"
require "tmpdir"
require "json"
require "open3"

gvm, project, compiled, output = ARGV
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

  # Match the CSS family to a local asset basename, independent of its internal
  # PostScript name. WOFF2 is a build input; the native host receives an sfnt.
  public_dir = File.join(project, "public")
  files = Dir.glob("**/*.{woff2,otf,ttf}", base: public_dir).sort
  scene["fonts"] = {}
  families = scene["styles"].map { |rule| rule["values"]["face"] }.compact.uniq
  families.each do |family|
    next if %w[sans-serif monospace].include?(family)
    matches = files.select { |f| File.basename(f, ".*").downcase.delete("-_") == family.downcase.delete("-_") }
    abort "#{scene['source']}: expected one bundled font named for #{family} under public/" unless matches.one?
    source = File.join(public_dir, matches.first)
    if File.extname(source) == ".woff2"
      temp = File.join(work, "font.woff2")
      FileUtils.cp(source, temp)
      checked("woff2_decompress", temp)
      source = File.join(work, "font.ttf")
    end
    name = "font-#{scene['fonts'].size}#{File.extname(source)}"
    FileUtils.cp(source, File.join(resources, name))
    scene["fonts"][family] = name
  end
  licenses = Dir.glob("**/{OFL,LICENSE}*.{txt,md}", base: public_dir).sort
  licenses.each_with_index do |file, i|
    FileUtils.cp(File.join(public_dir, file), File.join(resources, "#{i}-#{File.basename(file)}"))
  end
  FileUtils.cp(File.expand_path("../clay/LICENSE.clay.txt", __dir__), resources)
  File.write(File.join(resources, "scene.json"), JSON.generate(scene))
  plist = File.join(app, "Contents", "Info.plist")
  identifier = "org.mochi.desktop." + scene.fetch("class").gsub(/[^A-Za-z0-9-]/, "-")
  File.write(plist, JSON.generate({
    CFBundleIdentifier: identifier, CFBundleExecutable: "Mochi", CFBundlePackageType: "APPL",
    CFBundleName: scene.fetch("class"), CFBundleVersion: "1", NSHighResolutionCapable: true,
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
