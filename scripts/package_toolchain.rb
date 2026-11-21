#!/usr/bin/env ruby
# frozen_string_literal: true

require "tmpdir"
require_relative "install_dev"
require_relative "toolchain_archive"

class MacLibraries
  SYSTEM_LIBRARIES = %r{\A(?:/usr/lib/|/System/Library/)}.freeze

  def initialize(root, cpu)
    @root = root
    @cpu = cpu
    @libraries = {}
    @dependency_roots = {}
  end

  def add(source, relative)
    source = File.realpath(source)
    return @libraries[source] if @libraries.key?(source)

    @libraries[source] = relative
    destination = File.join(@root, relative)
    raise "multiple libraries resolve to #{relative}" if File.exist?(destination)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(source, destination)
    File.chmod(0o755, destination)
    ToolchainArchive.check_cpu(destination, @cpu)

    id = ToolchainArchive.command("otool", "-D", source).lines[1]&.strip
    rpaths = ToolchainArchive.command("otool", "-l", source).scan(/cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)/).flatten
    changes = rpaths.select { |path| path.start_with?("/") }.flat_map { |path| ["-delete_rpath", path] }
    loads = ToolchainArchive.command("otool", "-L", source).lines.drop(1).map do |line|
      line.strip.split(/ \(compatibility version /, 2).first
    end
    loads.reject { |path| path == id || SYSTEM_LIBRARIES.match?(path) }.each do |load|
      dependency = resolve(load, source, rpaths)
      library = add(dependency, "lib/#{File.basename(load)}")
      relative_library = relative.start_with?("bin/") ? "../#{library}" : File.basename(library)
      replacement = "@loader_path/#{relative_library}"
      changes.concat(["-change", load, replacement]) unless load == replacement
      homebrew_root = File.realpath(dependency)[%r{\A.*?/Cellar/[^/]+/[^/]+}]
      @dependency_roots[homebrew_root] = true if homebrew_root
    end
    changes.concat(["-id", "@loader_path/#{File.basename(destination)}"]) if id && !id.empty?
    unless changes.empty?
      ToolchainArchive.command("install_name_tool", *changes, destination)
      ToolchainArchive.command("codesign", "--force", "--sign", "-", destination)
    end
    relative
  end

  def copy_licenses
    @dependency_roots.keys.sort.each do |root|
      name = File.basename(File.dirname(root))
      target = File.join(@root, "licenses", name)
      documents = Dir.children(root).grep(/\A(?:licen[cs]e|copying|notice|copyright)/i)
      documents << "README.md" if name == "bdw-gc"
      FileUtils.mkdir_p(target)
      documents.sort.each do |document|
        source = File.join(root, document)
        FileUtils.cp(source, target) if File.file?(source)
      end
    end
  end

  private

  def resolve(load, source, rpaths)
    directory = File.dirname(source)
    candidates = if load.start_with?("@rpath/")
      rpaths.map do |path|
        File.join(path.sub(/\A@(?:loader|executable)_path/, directory), load.delete_prefix("@rpath/"))
      end
    else
      [load.sub(/\A@(?:loader|executable)_path/, directory)]
    end
    candidates.find { |path| File.file?(path) } || raise("cannot resolve #{load} linked by #{source}")
  end
end

def copy_resource(source, root, relative)
  destination = File.join(root, relative)
  FileUtils.mkdir_p(File.dirname(destination))
  FileUtils.cp(source, destination, preserve: true)
  relative
end

def executable(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |path| File.join(path, name) }.find { |path| executable_file?(path) }
end

def copy_optional_licenses(source, root, label)
  Dir.glob(File.join(source, "{LICENSE,LICENSE.*,NOTICE,NOTICE.*,COPYING,COPYING.*}")).sort.each do |file|
    copy_resource(file, root, "licenses/#{label}/#{File.basename(file)}") if File.file?(file)
  end
end

def package_core(root, checkout, gvm, cpu)
  files = runtime_files(checkout, gvm)
  decoder = ENV["MOCHI_WOFF2_DECOMPRESS"] || executable("woff2_decompress")
  raise "woff2_decompress is missing; install it or set MOCHI_WOFF2_DECOMPRESS" unless decoder && executable_file?(decoder)
  libraries = MacLibraries.new(root, cpu)
  paths = {
    "compiler" => libraries.add(File.join(checkout, "compiler/mochi"), "bin/mochi"),
    "mrbc" => libraries.add(files["mrbc"] || raise("mrbc is missing"), "bin/mrbc"),
    "woff2_decoder" => libraries.add(decoder, "bin/woff2_decompress")
  }
  {"gvm_wasm" => "mochi-gvm.wasm", "gvm_js" => "mochi-gvm.js", "gvm_capacity" => "mochi-gvm.capacity.json",
   "loader" => "mochi-loader.js"}.each do |key, name|
    paths[key] = copy_resource(files[key] || raise("#{key} is missing"), root, "runtime/#{name}")
  end
  adapters = Dir.glob(File.join(checkout, "runtime/mochi-*.js")).sort.reject { |path| File.basename(path) == "mochi-loader.js" }.to_h do |file|
    name = File.basename(file)
    override = case name
    when "mochi-format.js" then files["format_host"]
    when "mochi-fetch.js" then files["mochi-fetch.js"]
    end
    [name, copy_resource(override || file, root, "runtime/#{name}")]
  end
  copy_resource(File.join(__dir__, "install_dev.rb"), root, "install.rb")
  copy_resource(File.join(__dir__, "toolchain_archive.rb"), root, "toolchain_archive.rb")
  copy_resource(File.join(checkout, "LICENSE.md"), root, "licenses/mochi/LICENSE.md")
  copy_resource(File.join(checkout, "runtime/toolchain/THIRD_PARTY.md"), root, "licenses/THIRD_PARTY.md")
  Dir.glob(File.join(checkout, "runtime/toolchain/licenses/*.txt")).sort.each do |license|
    copy_resource(license, root, "licenses/#{File.basename(license)}")
  end
  if crystal = executable("crystal")
    copy_optional_licenses(File.expand_path("../..", File.realpath(crystal)), root, "crystal")
  end
  licenses = [checkout, gvm].map { |base| File.join(base, "build_wasm/mruby/src/LICENSE") }
  mruby_license = licenses.find { |file| File.file?(file) } || raise("cannot locate mruby license")
  copy_resource(mruby_license, root, "licenses/mruby/LICENSE")
  copy_optional_licenses(gvm, root, "mochi-gvm")
  libraries.copy_licenses

  fingerprint = JSON.parse(File.read(File.join(root, paths.fetch("gvm_capacity")))).fetch("fingerprint")
  metadata = ToolchainArchive.core_identity(cpu).merge("capacity_fingerprint" => fingerprint,
    "paths" => paths, "host_adapters" => adapters)
  ToolchainArchive.describe(root, "toolchain.json", metadata)
  metadata
end

def package_desktop(root, core, checkout, gvm, cpu, metadata)
  native = File.join(checkout, "runtime/desktop")
  identity = ToolchainArchive.desktop_identity(cpu, metadata.fetch("capacity_fingerprint"))
  paths = %w[host replay].to_h do |name|
    relative = "bin/#{name}"
    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    entry = name == "host" ? "main.m" : "test/replay.m"
    ToolchainArchive.command(File.join(native, "build_host.sh"), gvm, File.join(native, entry), destination, "-arch", cpu)
    ToolchainArchive.verify_native(destination, identity)
    [name, relative]
  end
  paths["packager"] = copy_resource(File.join(native, "package.rb"), root, "package.rb")
  paths["clay_license"] = copy_resource(File.join(checkout, "runtime/clay/LICENSE.clay.txt"), root, "licenses/LICENSE.clay.txt")
  copy_resource(File.join(checkout, "LICENSE.md"), root, "licenses/LICENSE.mochi.md")
  copy_resource(File.join(core, "licenses/mruby/LICENSE"), root, "licenses/mruby/LICENSE")
  goose = executable("goose") || raise("goose is missing; its license is required when packaging the generated VM")
  goose_root = File.dirname(File.realpath(goose))
  copy_resource(File.join(goose_root, "LICENSE"), root, "licenses/goose/LICENSE")
  copy_optional_licenses(gvm, root, "mochi-gvm")
  pairing = %w[compiler mrbc].to_h do |key|
    ["#{key}_sha256", ToolchainArchive.checksum(File.join(core, metadata.fetch("paths").fetch(key)))]
  end
  ToolchainArchive.describe(root, "desktop.json", identity.merge(pairing).merge(
    "schema_version" => ToolchainArchive::SCHEMA, "paths" => paths))
end

begin
  output = "build/toolchains"
  desktop = false
  OptionParser.new do |options|
    options.banner = "Usage: ruby scripts/package_toolchain.rb [--output PATH] [--desktop]"
    options.on("--output PATH", "Archive destination") { |value| output = value }
    options.on("--desktop", "Also package the prelinked desktop target") { desktop = true }
    options.on("-h", "--help", "Show help") { puts options; exit 0 }
  end.parse!
  raise "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?

  checkout = File.expand_path("..", __dir__)
  gvm = File.expand_path(ENV["MOCHI_GVM_DIR"] || File.join(checkout, "../mochi-gvm"))
  cpu = ToolchainArchive.architecture
  FileUtils.mkdir_p(output)
  Dir.mktmpdir("mochi-toolchain-") do |work|
    core = File.join(work, "core")
    metadata = package_core(core, checkout, gvm, cpu)
    target = File.join(work, "desktop")
    package_desktop(target, core, checkout, gvm, cpu, metadata) if desktop
    core_archive = File.join(output, "mochi-macos-#{cpu}.tar.gz")
    ToolchainArchive.write(core, core_archive)
    puts core_archive
    if desktop
      desktop_archive = File.join(output, "mochi-desktop-macos-#{cpu}.tar.gz")
      ToolchainArchive.write(target, desktop_archive)
      puts desktop_archive
    end
  end
rescue RuntimeError, SystemCallError, OptionParser::ParseError => error
  abort "mochi package: #{error.message}"
end
