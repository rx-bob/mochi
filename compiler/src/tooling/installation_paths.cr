require "json"
require "path"
require "digest/sha256"
require "../gvm/package_graph"
require "../gvm/capacity_config"
require "../clay/desktop_scene"

record DesktopTools, packager : String, host : String?, replay : String?, gvm : String?,
  clay_license : String, archive_root : String?, notices : Array(String)

# Resolves Mochi's development resources from explicit overrides, an installed
# development record, then paths inside this compiler's source checkout.
class InstallationPaths
  RECORD_SCHEMA_VERSION  = 1
  DEVELOPMENT_ROOT       = File.expand_path(Path[__DIR__, "../../.."].to_s)
  MANIFEST_SCHEMA        = MochiPackaging::SCHEMA_VERSION
  DESKTOP_PACKAGE_SCHEMA = 1
  DESKTOP_NATIVE_ABI     = 3

  getter record_path : String?
  getter development_root : String

  @environment : Hash(String, String)
  @record : Hash(String, JSON::Any)?

  def initialize(
    @environment : Hash(String, String) = ENV.to_h,
    @development_root : String = DEVELOPMENT_ROOT,
  )
    @record_path = @environment["MOCHI_INSTALL_RECORD"]?
    @record = read_record(@record_path)
    if archive_install?
      @development_root = File.dirname(@record_path.not_nil!)
    end
  end

  def compiler : String?
    resolve("MOCHI_COMPILER", "compiler", [File.join(@development_root, "compiler", "mochi")], true)
  end

  def mrbc : String?
    resolve("MRBC", "mrbc", mrbc_defaults, true)
  end

  def wasm : String?
    resolve("MOCHI_GVM_WASM", "gvm_wasm", wasm_defaults)
  end

  def js : String?
    if @environment["MOCHI_GVM_JS"]?
      return selected("MOCHI_GVM_JS", "gvm_js")
    end
    if wasm_override = @environment["MOCHI_GVM_WASM"]?
      sibling = wasm_override.sub(/\.wasm\z/, ".js")
      if File.file?(sibling)
        return File.expand_path(sibling)
      end
      raise setup_error("MOCHI_GVM_WASM override has no sibling runtime JS at #{sibling}; set MOCHI_GVM_JS to the matching file")
    end
    resolve("MOCHI_GVM_JS", "gvm_js", js_defaults)
  end

  def loader : String?
    resolve("MOCHI_LOADER", "loader", [File.join(@development_root, "runtime", "mochi-loader.js")])
  end

  def format_host : String?
    host_adapter("mochi-format.js")
  end

  def host_adapter(host : String) : String?
    name = File.basename(host)
    environment_key = host_adapter_override(name)
    if override = @environment[environment_key]?
      return validate_path(override, environment_key, false, false)
    end

    if path = recorded_host_adapter(name)
      return validate_path(path, "installation record host adapter '#{name}'", false, false, relative_to_record: true)
    end
    resolve(environment_key, "", [File.join(@development_root, "runtime", name)])
  end

  def playwright_node_modules : String?
    resolve(
      "MOCHI_E2E_NODE_MODULES",
      "playwright_node_modules",
      [File.join(@development_root, "e2e", "node_modules")],
      directory: true
    )
  end

  def gvm_root : String?
    defaults = [File.expand_path(File.join(@development_root, "..", "mochi-gvm"))]
    resolve("MOCHI_GVM_DIR", "gvm_root", archive_install? ? [] of String : defaults, directory: true)
  end

  def woff2_decoder : String?
    selected("MOCHI_WOFF2_DECOMPRESS", "woff2_decoder", executable: true) || Process.find_executable("woff2_decompress")
  end

  def desktop_tools! : DesktopTools
    compiler_path = compiler || raise(setup_error("compiler resource is missing"))
    mrbc_path = mrbc || raise(setup_error("mrbc not found; set MRBC or install the matching toolchain"))
    if path = selected("MOCHI_DESKTOP_TOOLCHAIN", "desktop_toolchain", directory: true)
      return read_desktop_tools(path, compiler_path, mrbc_path)
    end
    if archive_install?
      raise setup_error("desktop toolchain is missing from installation record #{@record_path}; install the matching desktop archive")
    end
    source = gvm_root || raise(setup_error("desktop needs a matching GVM source checkout or MOCHI_DESKTOP_TOOLCHAIN"))
    host_root = File.join(@development_root, "runtime", "desktop")
    %w[dist/goose_vm.c src/gvm/include/mochi_native.h src/gvm/include/mochi_capacity_profile.h].each do |file|
      validate_path(File.join(source, file), "desktop GVM checkout", false, false)
    end
    header = File.read(File.join(source, "src/gvm/include/mochi_native.h"))
    unless header.matches?(/MOCHI_NATIVE_ABI_VERSION\s+#{DESKTOP_NATIVE_ABI}\b/)
      raise setup_error("#{source}/src/gvm/include/mochi_native.h requires native ABI #{DESKTOP_NATIVE_ABI}")
    end
    capacity = File.join(source, "src/gvm/include/mochi_capacity_profile.h")
    unless File.read(capacity).includes?(%("#{CapacityConfig.default.fingerprint}"))
      raise setup_error("#{capacity} does not match compiler capacity #{CapacityConfig.default.fingerprint}")
    end
    DesktopTools.new(File.join(host_root, "package.rb"), nil, nil, source,
      File.join(@development_root, "runtime/clay/LICENSE.clay.txt"), nil, [] of String)
  end

  private def read_desktop_tools(root : String, compiler_path : String, mrbc_path : String) : DesktopTools
    descriptor = File.join(root, "desktop.json")
    metadata = JSON.parse(File.read(descriptor)).as_h
    expected = {
      "schema_version"       => JSON::Any.new(DESKTOP_PACKAGE_SCHEMA.to_i64),
      "target"               => JSON::Any.new("desktop"),
      "platform"             => JSON::Any.new("macos"),
      "architecture"         => JSON::Any.new({{ flag?(:aarch64) ? "arm64" : "x86_64" }}),
      "scene_schema"         => JSON::Any.new(DesktopScene::VERSION.to_i64),
      "native_abi"           => JSON::Any.new(DESKTOP_NATIVE_ABI.to_i64),
      "capacity_fingerprint" => JSON::Any.new(CapacityConfig.default.fingerprint),
    }
    expected.each do |key, value|
      unless metadata[key]? == value
        raise setup_error("#{descriptor} #{key} mismatch (expected #{value}, found #{metadata[key]? || "missing"})")
      end
    end
    {"compiler_sha256" => compiler_path, "mrbc_sha256" => mrbc_path}.each do |key, path|
      unless metadata[key]?.try(&.as_s?) == Digest::SHA256.hexdigest(File.read(path))
        raise setup_error("#{path} does not match #{key} in #{descriptor}")
      end
    end
    files = metadata["files"].as_h
    files.each do |relative, digest|
      artifact = desktop_artifact(root, relative)
      unless digest.as_s? == Digest::SHA256.hexdigest(File.read(artifact))
        raise setup_error("#{artifact} does not match its SHA-256 in #{descriptor}")
      end
    end
    paths = metadata["paths"].as_h
    host = desktop_path(root, paths, files, "host")
    replay = desktop_path(root, paths, files, "replay")
    [host, replay].each do |artifact|
      verify_desktop_executable!(artifact, expected)
    end
    notices = files.keys.select(&.starts_with?("licenses/")).sort
    DesktopTools.new(desktop_path(root, paths, files, "packager"), host, replay, nil,
      desktop_path(root, paths, files, "clay_license"), root, notices)
  rescue ex : JSON::ParseException | KeyError | TypeCastError | File::Error
    raise setup_error("invalid desktop toolchain at #{descriptor}: #{ex.message}")
  end

  private def desktop_artifact(root : String, relative : String) : String
    unless relative.matches?(/\A[A-Za-z0-9_.@+-]+(?:\/[A-Za-z0-9_.@+-]+)*\z/) &&
           relative.split('/').none? { |part| part.in?(".", "..") }
      raise setup_error("#{root}/desktop.json has invalid artifact path #{relative.inspect}")
    end
    artifact = File.join(root, relative)
    unless File.file?(artifact) && File.realpath(artifact) == File.join(File.realpath(root), relative)
      raise setup_error("desktop toolchain artifact #{artifact} is missing or is a symlink")
    end
    artifact
  end

  private def desktop_path(root, paths, files, key) : String
    relative = paths[key].as_s
    raise setup_error("#{root}/desktop.json has no identity for #{relative}") unless files.has_key?(relative)
    desktop_artifact(root, relative)
  end

  private def verify_desktop_executable!(artifact : String, expected : Hash(String, JSON::Any)) : Nil
    validate_path(artifact, "desktop toolchain artifact", true, false)
    header = Bytes.new(8)
    architecture = File.open(artifact) do |file|
      if file.read(header) == header.size && header[0, 4] == Bytes[0xcf, 0xfa, 0xed, 0xfe]
        case IO::ByteFormat::LittleEndian.decode(UInt32, header[4, 4])
        when 0x0100000c then "arm64"
        when 0x01000007 then "x86_64"
        end
      end
    end
    unless architecture == expected["architecture"].as_s
      raise setup_error("#{artifact} has wrong Mach-O architecture (expected #{expected["architecture"]}, found #{architecture || "unknown"})")
    end
    probe = IO::Memory.new
    status = Process.run(artifact, ["--mochi-toolchain-info"], output: probe, error: probe)
    raise setup_error("#{artifact} failed the native toolchain probe: #{probe.to_s.strip}") unless status.success?
    actual = JSON.parse(probe.to_s).as_h
    expected.each do |key, value|
      next if key == "schema_version"
      unless actual[key]? == value
        raise setup_error("#{artifact} reports incompatible #{key} (expected #{value}, found #{actual[key]? || "missing"})")
      end
    end
  rescue ex : JSON::ParseException | TypeCastError | IO::Error
    raise setup_error("#{artifact} failed the native toolchain probe: #{ex.message}")
  end

  # Validate all artifacts needed by a standard build before output cleanup or
  # compilation begins. Runtime identity includes the selected default capacity
  # profile; current bundles use manifest schema 3.
  def validate_build_resources! : Nil
    compiler = required_path("MOCHI_COMPILER", "compiler", [File.join(@development_root, "compiler", "mochi")], executable: true)
    mrbc || raise(setup_error("required resource 'mrbc' not found; set MRBC or run `task install`"))
    wasm_path = wasm || raise(setup_error("required runtime WASM not found; set MOCHI_GVM_WASM or run `task install`"))
    js_path = js || raise(setup_error("required runtime JS not found; set MOCHI_GVM_JS or run `task install`"))
    loader_path = required_path("MOCHI_LOADER", "loader", [File.join(@development_root, "runtime", "mochi-loader.js")])

    wasm = File.read(wasm_path)
    unless wasm.bytesize >= 8 && wasm.byte_slice(0, 4) == "\0asm"
      raise setup_error("#{wasm_path} is not a WebAssembly runtime; rebuild Mochi GVM with `task gvm:wasm`")
    end
    validate_capacity_profile!(wasm_path)
    runtime_js = File.read(js_path)
    raise setup_error("#{js_path} is empty; rebuild Mochi GVM with `task gvm:wasm`") if runtime_js.empty?
    unless runtime_js.includes?("MochiModule")
      raise setup_error("#{js_path} is not Mochi's GVM JavaScript runtime; rebuild with `task gvm:wasm`")
    end

    loader = File.read(loader_path)
    unless loader.matches?(/MANIFEST_SCHEMA_VERSION\s*=\s*#{MANIFEST_SCHEMA}\b/)
      raise setup_error("#{loader_path} does not support bundle schema #{MANIFEST_SCHEMA}; update Mochi runtime resources")
    end
    unless compiler
      raise setup_error("compiler resource is missing; run `task build` or `task install`")
    end
    validate_record_identity!({compiler, wasm_path, js_path})
  end

  def validate_runtime_artifacts!(hosts : Array(String) = [] of String) : Nil
    validate_build_resources!
    hosts.each do |host|
      host_adapter(host) || raise(setup_error("host adapter '#{host}' missing; set #{host_adapter_override(File.basename(host))} or rerun `task install`"))
    end
  end

  private def host_adapter_override(name : String) : String
    name == "mochi-format.js" ? "MOCHI_FORMAT_HOST" : "MOCHI_HOST_ADAPTER_#{name.upcase.gsub(/[^A-Z0-9]/, "_")}"
  end

  def required_test_dependencies! : String
    path = playwright_node_modules
    return path if path

    raise setup_error(
      "Playwright dependencies not found; run `npm ci` in the Mochi development checkout or set MOCHI_E2E_NODE_MODULES"
    )
  end

  def validate_test_dependencies!(node_modules : String) : Nil
    unless File.file?(File.join(node_modules, "playwright", "package.json"))
      raise setup_error("Playwright package missing from #{node_modules}; run `npm ci` in the Mochi development checkout or set MOCHI_E2E_NODE_MODULES")
    end
    unless Process.find_executable("node")
      raise setup_error("Node.js is not on PATH; install Node.js before running `mochi test`")
    end
  end

  private def mrbc_defaults : Array(String)
    root = gvm_root
    defaults = [
      File.join(@development_root, "build_wasm", "mruby", "src", "build", "mochi-v2-host", "bin", "mrbc"),
      File.join(@development_root, "build_wasm", "mruby", "src", "build", "host", "bin", "mrbc"),
    ]
    if root
      defaults.concat([
        File.join(root, "build_wasm", "mruby", "src", "build", "mochi-v2-host", "bin", "mrbc"),
        File.join(root, "build_wasm", "mruby", "src", "build", "host", "bin", "mrbc"),
      ])
    end
    defaults
  end

  private def validate_capacity_profile!(wasm_path : String) : Nil
    profile_path = wasm_path.sub(/\.wasm\z/, ".capacity.json")
    unless File.file?(profile_path)
      raise setup_error("capacity profile metadata missing beside #{wasm_path}; rebuild GVM with `task gvm:wasm`")
    end
    actual = JSON.parse(File.read(profile_path))
    expected = JSON.parse(CapacityConfig.default.profile_json)
    return if actual == expected
    actual_fingerprint = actual.as_h?.try(&.["fingerprint"]?).try(&.as_s?) || "invalid"
    raise setup_error("default GVM capacity profile mismatch (expected #{CapacityConfig.default.fingerprint}, actual #{actual_fingerprint}); rebuild and reinstall matching Mochi runtime artifacts")
  rescue ex : JSON::ParseException
    raise setup_error("invalid capacity profile metadata at #{profile_path}: #{ex.message}")
  rescue ex : TypeCastError
    raise setup_error("invalid capacity profile metadata at #{profile_path}: expected an object")
  end

  private def wasm_defaults : Array(String)
    root = gvm_root
    root ? [File.join(root, "dist", "mochi-gvm.wasm")] : [] of String
  end

  private def js_defaults : Array(String)
    root = gvm_root
    root ? [File.join(root, "dist", "mochi-gvm.js")] : [] of String
  end

  private def required_path(
    environment_key : String,
    record_key : String,
    defaults : Array(String),
    executable : Bool = false,
  ) : String
    path = resolve(environment_key, record_key, defaults, executable)
    return path if path

    location = if record = @record_path
                 "installation record #{record}"
               else
                 "development checkout #{@development_root}"
               end
    raise setup_error(
      "required resource '#{record_key}' not found from #{location}; set #{environment_key} or run `task install`"
    )
  end

  private def archive_install? : Bool
    record_value("installation_kind") == "archive"
  end

  private def selected(environment_key : String, record_key : String, executable : Bool = false, directory : Bool = false) : String?
    resolve(environment_key, record_key, [] of String, executable, directory)
  end

  private def resolve(
    environment_key : String,
    record_key : String,
    defaults : Array(String),
    executable : Bool = false,
    directory : Bool = false,
  ) : String?
    if override = @environment[environment_key]?
      return validate_path(override, environment_key, executable, directory)
    end

    if value = record_value(record_key)
      return validate_path(value, "installation record '#{record_key}'", executable, directory, relative_to_record: true)
    end

    defaults.each do |path|
      return File.expand_path(path) if valid_path?(path, executable, directory)
    end
    nil
  end

  private def validate_path(
    path : String,
    source : String,
    executable : Bool,
    directory : Bool,
    relative_to_record : Bool = false,
  ) : String
    expanded = if relative_to_record && !Path[path].absolute? && @record_path
                 File.expand_path(path, File.dirname(@record_path.not_nil!))
               else
                 File.expand_path(path)
               end
    return expanded if valid_path?(expanded, executable, directory)

    expected = executable ? "executable file" : directory ? "directory" : "file"
    detail = executable ? " (check execute permission)" : ""
    raise setup_error("#{source} points to missing #{expected} #{expanded}#{detail}; correct the override or rerun `task install`")
  end

  private def valid_path?(path : String, executable : Bool, directory : Bool) : Bool
    return Dir.exists?(path) if directory
    return false unless File.file?(path)
    !executable || File.info?(path).try(&.permissions.owner_execute?) || false
  end

  private def read_record(path : String?) : Hash(String, JSON::Any)?
    return nil unless path
    expanded = File.expand_path(path)
    unless File.file?(expanded)
      raise setup_error("MOCHI_INSTALL_RECORD points to missing file #{expanded}; reinstall with `task install`")
    end
    parsed = begin
      JSON.parse(File.read(expanded)).as_h
    rescue ex
      raise setup_error("invalid installation record #{expanded}: #{ex.message}; rerun `task install`")
    end
    version = parsed["schema_version"]?.try(&.as_i?)
    unless version == RECORD_SCHEMA_VERSION
      raise setup_error("installation record #{expanded} uses schema #{version || "unknown"}; rerun `task install`")
    end
    @record_path = expanded
    parsed
  end

  private def record_value(key : String) : String?
    value = @record.try(&.[key]?)
    return nil unless value
    return nil if value.raw.nil?
    value.as_s
  rescue
    raise setup_error("installation record #{@record_path} has invalid '#{key}' path; rerun `task install`")
  end

  private def recorded_host_adapter(host : String) : String?
    adapters = @record.try(&.["host_adapters"]?)
    return nil unless adapters
    value = adapters.as_h[host]?
    return nil unless value
    return nil if value.raw.nil?
    value.as_s
  rescue
    raise setup_error("installation record #{@record_path} has invalid host adapter '#{host}'; rerun `task install`")
  end

  private def validate_record_identity!(paths : Tuple(String, String, String)) : Nil
    return unless @record

    owner = record_value("owner")
    unless owner == "mochi-development-install"
      raise setup_error("installation record owner is missing or invalid; reinstall with `task install`")
    end
    profile = record_value("runtime_profile")
    unless profile == "default"
      raise setup_error("installation record is missing a supported runtime profile; rerun `task install:update`") if profile.nil?
      raise setup_error("installed runtime profile '#{profile}' is not supported by this compiler; rebuild and reinstall matching Mochi runtime artifacts")
    end
    fingerprint = record_value("capacity_fingerprint")
    unless fingerprint == CapacityConfig.default.fingerprint
      raise setup_error("installed capacity fingerprint #{fingerprint || "missing"} does not match the default compiler profile; run `task install:update`")
    end
    schema = @record.not_nil!["manifest_schema"]?.try(&.as_i?)
    unless schema == MANIFEST_SCHEMA
      raise setup_error("installed compiler/runtime manifest schema #{schema || "missing"} does not match #{MANIFEST_SCHEMA}; run `task build` and `task install:update`")
    end

    identities = [
      {paths[0], "compiler_sha256"},
      {paths[1], "gvm_wasm_sha256"},
      {paths[2], "gvm_js_sha256"},
      {paths[1].sub(/\.wasm\z/, ".capacity.json"), "gvm_capacity_sha256"},
    ]
    identities.each do |path, key|
      expected = record_value(key)
      raise setup_error("installation record is missing #{key}; rerun `task install:update`") unless expected
      unless expected.matches?(/\A[0-9a-f]{64}\z/)
        raise setup_error("installation record has invalid #{key}; rerun `task install:update`")
      end
      actual = Digest::SHA256.hexdigest(File.read(path))
      next if actual == expected
      label = key.sub("_sha256", "")
      raise setup_error("#{label} does not match installed runtime identity; update the matching artifacts and run `task install:update`")
    end
  end

  private def setup_error(message : String) : String
    "Mochi setup: #{message}"
  end
end
