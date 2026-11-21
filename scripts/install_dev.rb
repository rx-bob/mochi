#!/usr/bin/env ruby
# Installs Mochi from a development checkout or a prebuilt toolchain.
require "fileutils"
require "json"
require "optparse"
require "shellwords"
require "digest"
require "tmpdir"
require_relative "toolchain_archive"

OWNER = "mochi-development-install"
SCHEMA_VERSION = 1
MANIFEST_SCHEMA_VERSION = 3
LAUNCHER_MARKER = "# mochi-managed-launcher-v1"

def fail_setup(message)
  warn "mochi install: #{message}"
  exit 2
end

def executable_file?(path)
  File.file?(path) && File.executable?(path)
end

def runtime_files(checkout_root, gvm_root)
  overrides = {
    "mrbc" => ENV["MRBC"],
    "gvm_wasm" => ENV["MOCHI_GVM_WASM"],
    "gvm_js" => ENV["MOCHI_GVM_JS"],
    "loader" => ENV["MOCHI_LOADER"],
    "format_host" => ENV["MOCHI_FORMAT_HOST"],
    "mochi-fetch.js" => ENV["MOCHI_HOST_ADAPTER_MOCHI_FETCH_JS"],
  }
  defaults = {
    "mrbc" => [
      File.join(checkout_root, "build_wasm/mruby/src/build/mochi-v2-host/bin/mrbc"),
      File.join(checkout_root, "build_wasm/mruby/src/build/host/bin/mrbc"),
      File.join(gvm_root, "build_wasm/mruby/src/build/mochi-v2-host/bin/mrbc"),
      File.join(gvm_root, "build_wasm/mruby/src/build/host/bin/mrbc"),
    ],
    "gvm_wasm" => [File.join(gvm_root, "dist/mochi-gvm.wasm")],
    "gvm_js" => [File.join(gvm_root, "dist/mochi-gvm.js")],
    "loader" => [File.join(checkout_root, "runtime/mochi-loader.js")],
    "format_host" => [File.join(checkout_root, "runtime/mochi-format.js")],
    "mochi-fetch.js" => [File.join(checkout_root, "runtime/mochi-fetch.js")],
  }
  result = {}
  if ENV["MOCHI_GVM_WASM"] && !ENV["MOCHI_GVM_JS"]
    sibling = ENV["MOCHI_GVM_WASM"].sub(/\.wasm\z/, ".js")
    unless File.file?(sibling)
      fail_setup("MOCHI_GVM_WASM override has no sibling runtime JS at #{sibling.inspect}; set MOCHI_GVM_JS to the matching file")
    end
    overrides["gvm_js"] = sibling
  end
  defaults.each do |key, candidates|
    override = overrides[key]
    if override
      path = File.expand_path(override)
      valid = key == "mrbc" ? executable_file?(path) : File.file?(path)
      fail_setup("#{key} override #{path.inspect} is missing or invalid") unless valid
      result[key] = path
    else
      result[key] = candidates.find do |path|
        key == "mrbc" ? executable_file?(path) : File.file?(path)
      end
    end
  end
  if wasm = result["gvm_wasm"]
    profile = wasm.sub(/\.wasm\z/, ".capacity.json")
    result["gvm_capacity"] = File.file?(profile) ? profile : nil
  end
  result
end

def owned_install?(launcher, record_path, prefix)
  return false unless File.file?(launcher) && File.file?(record_path)
  return false if File.symlink?(launcher) || File.symlink?(record_path)
  launcher_text = File.read(launcher)
  record = JSON.parse(File.read(record_path))
  launcher_text.include?(LAUNCHER_MARKER) &&
    record["owner"] == OWNER &&
    record["install_prefix"] == prefix
rescue JSON::ParserError
  false
end

def write_atomically(path, contents, mode)
  FileUtils.mkdir_p(File.dirname(path))
  temporary = "#{path}.tmp-#{Process.pid}"
  File.write(temporary, contents)
  File.chmod(mode, temporary)
  File.rename(temporary, path)
ensure
  File.delete(temporary) if temporary && File.file?(temporary)
end

def archive_record(core_source, desktop_source, prefix, generation)
  cpu = ToolchainArchive.architecture
  core = File.join(generation, "core")
  ToolchainArchive.unpack(core_source, core)
  metadata = ToolchainArchive.validate(core, "toolchain.json", ToolchainArchive.core_identity(cpu), ToolchainArchive::CORE_PATHS)
  paths = metadata.fetch("paths").transform_values { |path| File.join(core, path) }
  %w[compiler mrbc woff2_decoder].each do |name|
    path = paths.fetch(name)
    raise "#{path} is not executable" unless executable_file?(path)
    ToolchainArchive.check_cpu(path, cpu)
  end
  wasm = paths.fetch("gvm_wasm")
  profile = paths.fetch("gvm_capacity")
  unless File.binread(wasm, 8) == "\0asm\x01\0\0\0".b && File.read(paths.fetch("gvm_js")).include?("MochiModule")
    raise "#{wasm} or its companion JavaScript is not a Mochi GVM runtime"
  end
  capacity_profile = JSON.parse(File.read(profile))
  capacity = capacity_profile.fetch("fingerprint")
  unless profile == wasm.sub(/\.wasm\z/, ".capacity.json") && capacity_profile["schema_version"] == 1 &&
      capacity.is_a?(String) && capacity.match?(/\A[0-9a-f]{64}\z/)
    raise "invalid capacity profile #{profile}"
  end
  ToolchainArchive.match!(metadata, {"capacity_fingerprint" => capacity}, File.join(core, "toolchain.json"))
  unless File.binread(paths.fetch("loader")).match?(/MANIFEST_SCHEMA_VERSION\s*=\s*#{MANIFEST_SCHEMA_VERSION}\b/)
    raise "#{paths.fetch('loader')} does not support bundle schema #{MANIFEST_SCHEMA_VERSION}"
  end
  adapters = metadata.fetch("host_adapters").to_h do |name, relative|
    unless File.basename(relative) == name && metadata.fetch("files").key?(relative)
      raise "invalid host adapter #{name} in #{core}/toolchain.json"
    end
    [name, File.join(core, relative)]
  end
  hashes = %w[compiler mrbc gvm_wasm gvm_js gvm_capacity].to_h do |key|
    ["#{key}_sha256", ToolchainArchive.checksum(paths.fetch(key))]
  end

  desktop = nil
  native = {}
  if desktop_source
    desktop = File.join(generation, "desktop")
    ToolchainArchive.unpack(desktop_source, desktop)
    native = ToolchainArchive.desktop_identity(cpu, capacity)
    expected = native.merge(hashes.slice("compiler_sha256", "mrbc_sha256")).merge("schema_version" => ToolchainArchive::SCHEMA)
    descriptor = ToolchainArchive.validate(desktop, "desktop.json", expected, ToolchainArchive::DESKTOP_PATHS)
    %w[host replay].each do |name|
      ToolchainArchive.verify_native(File.join(desktop, descriptor.fetch("paths").fetch(name)), native)
    end
    native = {
      "descriptor" => File.join(desktop, "desktop.json"),
      "schema_version" => descriptor.fetch("schema_version")
    }.merge(native).merge(descriptor.fetch("paths").transform_values { |path| File.join(desktop, path) })
  end

  paths.merge(hashes).merge(
    "owner" => OWNER, "schema_version" => SCHEMA_VERSION, "installation_kind" => "archive",
    "install_prefix" => prefix, "toolchain_dir" => generation, "core_toolchain" => File.join(core, "toolchain.json"),
    "architecture" => cpu, "platform" => "macos", "targets" => desktop ? ["dom", "desktop"] : ["dom"],
    "desktop_toolchain" => desktop, "desktop_identity" => desktop ? native : nil,
    "manifest_schema" => MANIFEST_SCHEMA_VERSION, "runtime_profile" => "default",
    "capacity_fingerprint" => capacity, "format_host" => adapters["mochi-format.js"], "host_adapters" => adapters
  )
end

def remove_toolchain_generation(share_dir, generation)
  return unless generation.is_a?(String)
  parent = File.join(share_dir, "toolchains")
  return unless File.dirname(generation) == parent && File.basename(generation).match?(/\Ainstall-[A-Za-z0-9-]+\z/)
  return unless File.directory?(generation) && !File.symlink?(parent) && !File.symlink?(generation)
  FileUtils.remove_entry_secure(generation)
  Dir.rmdir(parent) if Dir.empty?(parent)
end

def install_archive(core, desktop, prefix, share_dir, launcher, record_path, previous)
  parent = File.join(share_dir, "toolchains")
  raise "refusing to install through symlink #{parent}" if File.symlink?(parent)
  FileUtils.mkdir_p(parent)
  generation = Dir.mktmpdir("install-", parent)
  record = archive_record(core, desktop, prefix, generation)
  publish_record(launcher, record_path, record)
  installed = true
  remove_toolchain_generation(share_dir, previous["toolchain_dir"])
  report_install(launcher, record_path)
ensure
  remove_toolchain_generation(share_dir, generation) if generation && !installed
end

def main
  action = %w[install update remove].include?(ARGV.first) ? ARGV.shift : "install"
  prefix = ENV["MOCHI_INSTALL_PREFIX"] || File.join(Dir.home, ".local")
  core = __dir__ if File.file?(File.join(__dir__, "toolchain.json"))
  desktop = nil
  OptionParser.new do |options|
    options.banner = "Usage: ruby scripts/install_dev.rb [install|update|remove] [--prefix PATH] [--toolchain PATH] [--desktop PATH]"
    options.on("--prefix PATH", "User install prefix (default: ~/.local)") { |value| prefix = value }
    options.on("--toolchain PATH", "Install a prebuilt core archive or extracted directory") { |value| core = value }
    options.on("--desktop PATH", "Also install a matching desktop archive or extracted directory") { |value| desktop = value }
    options.on("-h", "--help", "Show help") { puts options; exit 0 }
  end.parse!
  fail_setup("unexpected arguments: #{ARGV.join(' ')}") unless ARGV.empty?
  fail_setup("--desktop requires --toolchain") if desktop && !core

  prefix = File.expand_path(prefix)
  share_dir = File.join(prefix, "share/mochi")

  FileUtils.mkdir_p(share_dir) unless action == "remove"
  if File.directory?(share_dir)
    File.open(share_dir) do |lock|
      lock.flock(File::LOCK_EX)
      install_locked(action, prefix, core, desktop)
    end
  else
    install_locked(action, prefix, core, desktop)
  end
end

def install_locked(action, prefix, core, desktop)
  bin_dir = File.join(prefix, "bin")
  share_dir = File.join(prefix, "share/mochi")
  launcher = File.join(bin_dir, "mochi")
  record_path = File.join(share_dir, "install.json")

  launcher_exists = File.exist?(launcher) || File.symlink?(launcher)
  record_exists = File.exist?(record_path) || File.symlink?(record_path)
  owned = owned_install?(launcher, record_path, prefix)
  previous = owned ? JSON.parse(File.read(record_path)) : {}

  if action == "remove"
    if !launcher_exists && !record_exists
      puts "Mochi development install not present at #{prefix}"
      return
    end
    fail_setup("refusing to remove files not owned by Mochi at #{prefix}") unless owned
    File.delete(launcher)
    File.delete(record_path)
    remove_toolchain_generation(share_dir, previous["toolchain_dir"])
    Dir.rmdir(bin_dir) if Dir.exist?(bin_dir) && Dir.empty?(bin_dir)
    Dir.rmdir(share_dir) if Dir.exist?(share_dir) && Dir.empty?(share_dir)
    puts "Removed Mochi development launcher and record from #{prefix}"
    return
  end

  if action == "update" && !owned
    fail_setup("no owned install found at #{prefix}; use install first")
  end
  if (launcher_exists || record_exists) && !owned
    fail_setup("#{launcher} or #{record_path} already exists and is not an owned Mochi install; choose another --prefix")
  end
  if core
    install_archive(core, desktop, prefix, share_dir, launcher, record_path, previous)
    return
  end
  checkout_root = File.expand_path("..", __dir__)
  compiler = File.join(checkout_root, "compiler/mochi")
  fail_setup("compiler binary missing at #{compiler}; run `task build` first") unless executable_file?(compiler)

  if ENV["MOCHI_GVM_DIR"] && !File.directory?(ENV["MOCHI_GVM_DIR"])
    fail_setup("MOCHI_GVM_DIR override #{ENV["MOCHI_GVM_DIR"].inspect} is not a directory")
  end
  gvm_root = File.expand_path(ENV["MOCHI_GVM_DIR"] || File.join(checkout_root, "..", "mochi-gvm"))
  files = runtime_files(checkout_root, gvm_root)
  required = %w[mrbc gvm_wasm gvm_js gvm_capacity loader]
  missing = required.reject { |key| files[key] }
  unless missing.empty?
    commands = missing.map do |key|
      case key
      when "mrbc" then "build mruby in #{gvm_root.inspect} or set MRBC"
      when "gvm_wasm", "gvm_js", "gvm_capacity" then "run `task gvm:wasm` in #{gvm_root.inspect} or set MOCHI_GVM_WASM/MOCHI_GVM_JS"
      when "loader" then "restore #{File.join(checkout_root, "runtime/mochi-loader.js").inspect} or set MOCHI_LOADER"
      end
    end
    fail_setup("required resources missing (#{missing.join(", ")}); #{commands.join("; ")}")
  end

  wasm = File.binread(files.fetch("gvm_wasm"))
  unless wasm.bytesize >= 8 && wasm.start_with?("\0asm".b)
    fail_setup("#{files.fetch("gvm_wasm")} is not a WebAssembly module; rebuild with `task gvm:wasm`")
  end
  if File.zero?(files.fetch("gvm_js"))
    fail_setup("#{files.fetch("gvm_js")} is empty; rebuild with `task gvm:wasm`")
  end
  unless File.read(files.fetch("gvm_js")).include?("MochiModule")
    fail_setup("#{files.fetch("gvm_js")} is not Mochi's GVM JavaScript runtime; rebuild with `task gvm:wasm`")
  end
  begin
    capacity_profile = JSON.parse(File.read(files.fetch("gvm_capacity")))
  rescue JSON::ParserError => error
    fail_setup("invalid GVM capacity profile at #{files.fetch("gvm_capacity")}: #{error.message}")
  end
  unless capacity_profile.is_a?(Hash) && capacity_profile["schema_version"] == 1 &&
         capacity_profile["fingerprint"].is_a?(String) && capacity_profile["fingerprint"].match?(/\A[0-9a-f]{64}\z/)
    fail_setup("#{files.fetch("gvm_capacity")} is not a valid GVM capacity profile; rebuild with `task gvm:wasm`")
  end
  loader_text = File.binread(files.fetch("loader"))
  unless loader_text.match?(/MANIFEST_SCHEMA_VERSION\s*=\s*#{MANIFEST_SCHEMA_VERSION}\b/)
    fail_setup("loader at #{files.fetch("loader")} does not support schema #{MANIFEST_SCHEMA_VERSION}; update Mochi runtime resources")
  end

  record = {
    "schema_version" => SCHEMA_VERSION,
    "owner" => OWNER,
    "install_prefix" => prefix,
    "checkout_root" => checkout_root,
    "compiler" => compiler,
    "compiler_sha256" => Digest::SHA256.file(compiler).hexdigest,
    "gvm_root" => gvm_root,
    "mrbc" => files["mrbc"],
    "gvm_wasm" => files["gvm_wasm"],
    "gvm_wasm_sha256" => Digest::SHA256.file(files.fetch("gvm_wasm")).hexdigest,
    "gvm_js" => files["gvm_js"],
    "gvm_js_sha256" => Digest::SHA256.file(files.fetch("gvm_js")).hexdigest,
    "gvm_capacity_sha256" => Digest::SHA256.file(files.fetch("gvm_capacity")).hexdigest,
    "capacity_fingerprint" => capacity_profile.fetch("fingerprint"),
    "loader" => files["loader"],
    "format_host" => files["format_host"],
    "host_adapters" => {
      "mochi-format.js" => files["format_host"],
      "mochi-fetch.js" => files["mochi-fetch.js"],
    },
    "playwright_node_modules" => begin
      override = ENV["MOCHI_E2E_NODE_MODULES"]
      candidate = override || File.join(checkout_root, "e2e/node_modules")
      if override && !File.directory?(candidate)
        fail_setup("MOCHI_E2E_NODE_MODULES override #{candidate.inspect} is not a directory")
      end
      File.directory?(candidate) ? File.expand_path(candidate) : nil
    end,
    "manifest_schema" => MANIFEST_SCHEMA_VERSION,
    "runtime_profile" => "default",
  }

  publish_record(launcher, record_path, record)
  remove_toolchain_generation(share_dir, previous["toolchain_dir"])
  report_install(launcher, record_path)
  puts "Playwright dependencies recorded" if record["playwright_node_modules"]
  puts "Ruby tests need Playwright dependencies; run npm ci in #{File.join(checkout_root, "e2e").inspect}" unless record["playwright_node_modules"]
end

def publish_record(launcher, record_path, record)
  previous = File.binread(record_path) if File.file?(record_path)
  compiler = record.fetch("compiler")
  record_json = JSON.pretty_generate(record) + "\n"
  launcher_text = <<~SH
    #!/bin/sh
    #{LAUNCHER_MARKER}
    if [ "${MOCHI_INSTALL_RECORD+x}" != x ]; then
      MOCHI_INSTALL_RECORD=#{Shellwords.escape(record_path)}
      export MOCHI_INSTALL_RECORD
    fi
    if [ "${MOCHI_COMPILER+x}" = x ]; then
      if [ ! -x "$MOCHI_COMPILER" ]; then
        printf '%s\\n' "mochi setup: MOCHI_COMPILER is not executable: $MOCHI_COMPILER" >&2
        exit 127
      fi
      exec "$MOCHI_COMPILER" "$@"
    fi
    exec #{Shellwords.escape(compiler)} "$@"
  SH
  write_atomically(record_path, record_json, 0o600)
  begin
    write_atomically(launcher, launcher_text, 0o755)
  rescue SystemCallError
    previous ? write_atomically(record_path, previous, 0o600) : File.unlink(record_path)
    raise
  end
end

def report_install(launcher, record_path)
  bin_dir = File.dirname(launcher)

  puts "Installed Mochi development launcher: #{launcher}"
  puts "Resource record: #{record_path}"
  unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).include?(bin_dir)
    puts "Add this to your shell environment: export PATH=#{Shellwords.escape(bin_dir)}:\"$PATH\""
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    main
  rescue RuntimeError, SystemCallError, OptionParser::ParseError, JSON::ParserError, KeyError => error
    fail_setup(error.message)
  end
end
