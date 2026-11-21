# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "zlib"

module ToolchainArchive
  SCHEMA = 1
  MANIFEST_SCHEMA = 3
  SCENE_SCHEMA = 9
  NATIVE_ABI = 3
  CORE_PATHS = %w[compiler mrbc gvm_wasm gvm_js gvm_capacity loader woff2_decoder].freeze
  DESKTOP_PATHS = %w[host replay packager clay_license].freeze
  MACH_CPUS = {0x0100000c => "arm64", 0x01000007 => "x86_64"}.freeze

  module_function

  def command(*args)
    output, status = Open3.capture2e(*args)
    raise "#{args.first} failed for #{args.drop(1).join(' ')}: #{output.strip}" unless status.success?
    output
  end

  def architecture
    raise "macOS is required for this toolchain" unless RUBY_PLATFORM.include?("darwin")
    cpu = command("uname", "-m").strip
    raise "unsupported Mac architecture #{cpu}" unless MACH_CPUS.value?(cpu)
    cpu
  end

  def check_cpu(path, expected)
    header = File.binread(path, 8) || "".b
    cpu = MACH_CPUS[header.unpack("V2")[1]] if header.start_with?("\xcf\xfa\xed\xfe".b)
    raise "#{path} has wrong Mach-O architecture (expected #{expected}, found #{cpu || 'unknown'})" unless cpu == expected
  end

  def path!(relative)
    unless relative.is_a?(String) && relative.match?(%r{\A[A-Za-z0-9_.@+-]+(?:/[A-Za-z0-9_.@+-]+)*\z}) &&
        (relative.split("/") & %w[. ..]).empty?
      raise "invalid toolchain artifact path #{relative.inspect}"
    end
    relative
  end

  def inventory(root)
    Dir.glob("**/*", base: root, flags: File::FNM_DOTMATCH).sort.map do |relative|
      next if File.basename(relative) == "."
      path!(relative)
      path = File.join(root, relative)
      stat = File.lstat(path)
      next if stat.directory?
      raise "#{path} is not a regular file" unless stat.file?
      relative
    end.compact
  end

  def checksum(path)
    Digest::SHA256.file(path).hexdigest
  end

  def describe(root, name, data)
    data["files"] = inventory(root).to_h { |path| [path, checksum(File.join(root, path))] }
    File.write(File.join(root, name), JSON.pretty_generate(data) + "\n")
  end

  def write(root, output)
    temporary = "#{output}.tmp-#{Process.pid}"
    Zlib::GzipWriter.open(temporary) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        inventory(root).each do |relative|
          path = File.join(root, relative)
          tar.add_file_simple(relative, File.executable?(path) ? 0o755 : 0o644, File.size(path)) do |entry|
            File.open(path, "rb") { |file| IO.copy_stream(file, entry) }
          end
        end
      end
    end
    File.rename(temporary, output)
  ensure
    FileUtils.rm_f(temporary) if temporary
  end

  def unpack(source, root)
    FileUtils.mkdir_p(root)
    if File.directory?(source)
      inventory(source).each do |relative|
        destination = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(source, relative), destination, preserve: true)
      end
    else
      Zlib::GzipReader.open(source) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            path = File.join(root, path!(entry.full_name))
            if entry.directory?
              FileUtils.mkdir_p(path)
              next
            end
            raise "invalid archive member #{entry.full_name}" unless entry.file?
            FileUtils.mkdir_p(File.dirname(path))
            mode = (entry.header.mode & 0o111).zero? ? 0o644 : 0o755
            File.open(path, File::WRONLY | File::CREAT | File::EXCL, mode) { |file| IO.copy_stream(entry, file) }
          end
        end
      end
    end
  rescue Zlib::Error, Gem::Package::TarInvalidError, SystemCallError => error
    raise "invalid archive #{source}: #{error.message}"
  end

  def validate(root, name, expected, required_paths)
    descriptor = File.join(root, name)
    actual = JSON.parse(File.read(descriptor))
    match!(actual, expected, descriptor)
    files = actual.fetch("files")
    unless files.is_a?(Hash) && inventory(root) == (files.keys + [name]).sort
      raise "#{descriptor} does not match its artifact inventory"
    end
    files.each do |relative, digest|
      path = File.join(root, relative)
      raise "#{path} does not match its SHA-256 in #{descriptor}" unless checksum(path) == digest
    end
    paths = actual.fetch("paths")
    unless paths.is_a?(Hash) && paths.keys.sort == required_paths.sort
      raise "#{descriptor} is missing required paths or contains unknown paths"
    end
    paths.each_value { |relative| files.fetch(relative) }
    actual
  rescue JSON::ParserError, KeyError, SystemCallError, TypeError, NoMethodError => error
    raise "invalid toolchain descriptor #{descriptor}: #{error.message}"
  end

  def match!(actual, expected, artifact)
    raise "#{artifact} must contain a JSON object" unless actual.is_a?(Hash)
    expected.each do |key, value|
      unless actual[key] == value
        raise "#{artifact} #{key} mismatch (expected #{value}, found #{actual[key] || 'missing'})"
      end
    end
  end

  def core_identity(cpu)
    {"schema_version" => SCHEMA, "target" => "dom", "platform" => "macos",
     "architecture" => cpu, "manifest_schema" => MANIFEST_SCHEMA}
  end

  def desktop_identity(cpu, capacity)
    {"target" => "desktop", "platform" => "macos", "architecture" => cpu,
     "scene_schema" => SCENE_SCHEMA, "native_abi" => NATIVE_ABI, "capacity_fingerprint" => capacity}
  end

  def verify_native(path, identity)
    check_cpu(path, identity.fetch("architecture"))
    actual = JSON.parse(command(path, "--mochi-toolchain-info"))
    match!(actual, identity, path)
  rescue JSON::ParserError => error
    raise "#{path} has an invalid native toolchain probe: #{error.message}"
  end
end
