#!/usr/bin/env ruby
# Installs a source-checkout-backed Mochi development launcher.
require "fileutils"
require "json"
require "optparse"
require "shellwords"
require "digest"

OWNER = "mochi-development-install"
SCHEMA_VERSION = 1
MANIFEST_SCHEMA_VERSION = 2
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
  result
end

def owned_install?(launcher, record_path, prefix)
  return false unless File.file?(launcher) && File.file?(record_path)
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

def main
  action = %w[install update remove].include?(ARGV.first) ? ARGV.shift : "install"
  unless %w[install update remove].include?(action)
    fail_setup("usage: install_dev.rb [install|update|remove] [--prefix PATH]")
  end
  prefix = ENV["MOCHI_INSTALL_PREFIX"] || File.join(Dir.home, ".local")
  OptionParser.new do |options|
    options.banner = "Usage: ruby scripts/install_dev.rb [install|update|remove] [--prefix PATH]"
    options.on("--prefix PATH", "User install prefix (default: ~/.local)") { |value| prefix = value }
    options.on("-h", "--help", "Show help") { puts options; exit 0 }
  end.parse!

  prefix = File.expand_path(prefix)
  checkout_root = File.expand_path("..", __dir__)
  compiler = File.join(checkout_root, "compiler/mochi")
  bin_dir = File.join(prefix, "bin")
  share_dir = File.join(prefix, "share/mochi")
  launcher = File.join(bin_dir, "mochi")
  record_path = File.join(share_dir, "install.json")

  launcher_exists = File.exist?(launcher) || File.symlink?(launcher)
  record_exists = File.exist?(record_path) || File.symlink?(record_path)
  owned = owned_install?(launcher, record_path, prefix)

  if action == "remove"
    if !launcher_exists && !record_exists
      puts "Mochi development install not present at #{prefix}"
      return
    end
    fail_setup("refusing to remove files not owned by Mochi at #{prefix}") unless owned
    File.delete(launcher)
    File.delete(record_path)
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
  fail_setup("compiler binary missing at #{compiler}; run `task build` first") unless executable_file?(compiler)

  if ENV["MOCHI_GVM_DIR"] && !File.directory?(ENV["MOCHI_GVM_DIR"])
    fail_setup("MOCHI_GVM_DIR override #{ENV["MOCHI_GVM_DIR"].inspect} is not a directory")
  end
  gvm_root = File.expand_path(ENV["MOCHI_GVM_DIR"] || File.join(checkout_root, "..", "mochi-gvm"))
  files = runtime_files(checkout_root, gvm_root)
  required = %w[mrbc gvm_wasm gvm_js loader]
  missing = required.reject { |key| files[key] }
  unless missing.empty?
    commands = missing.map do |key|
      case key
      when "mrbc" then "build mruby in #{gvm_root.inspect} or set MRBC"
      when "gvm_wasm", "gvm_js" then "run `task gvm:wasm` in #{gvm_root.inspect} or set MOCHI_GVM_WASM/MOCHI_GVM_JS"
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
  loader_text = File.read(files.fetch("loader"))
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
  write_atomically(launcher, launcher_text, 0o755)

  puts "Installed Mochi development launcher: #{launcher}"
  puts "Resource record: #{record_path}"
  unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).include?(bin_dir)
    puts "Add this to your shell environment: export PATH=#{Shellwords.escape(bin_dir)}:\"$PATH\""
  end
  puts "Playwright dependencies recorded" if record["playwright_node_modules"]
  puts "Ruby tests need Playwright dependencies; run npm ci in #{File.join(checkout_root, "e2e").inspect}" unless record["playwright_node_modules"]
end

main
