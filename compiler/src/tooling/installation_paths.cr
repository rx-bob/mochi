require "json"
require "path"
require "digest/sha256"
require "../gvm/package_graph"
require "../gvm/capacity_config"

# Resolves Mochi's development resources from explicit overrides, an installed
# development record, then paths inside this compiler's source checkout.
class InstallationPaths
  RECORD_SCHEMA_VERSION = 1
  DEVELOPMENT_ROOT      = File.expand_path(Path[__DIR__, "../../.."].to_s)
  MANIFEST_SCHEMA       = MochiPackaging::SCHEMA_VERSION

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
  end

  def compiler : String?
    resolve("MOCHI_COMPILER", "compiler", [File.join(@development_root, "compiler", "mochi")], true)
  end

  def mrbc : String?
    defaults = [
      File.join(@development_root, "build_wasm", "mruby", "src", "build", "mochi-v2-host", "bin", "mrbc"),
      File.join(@development_root, "build_wasm", "mruby", "src", "build", "host", "bin", "mrbc"),
    ]
    root = gvm_root
    if root
      defaults << File.join(root, "build_wasm", "mruby", "src", "build", "mochi-v2-host", "bin", "mrbc")
      defaults << File.join(root, "build_wasm", "mruby", "src", "build", "host", "bin", "mrbc")
    end
    resolve("MRBC", "mrbc", defaults, true)
  end

  def wasm : String?
    root = gvm_root
    defaults = root ? [File.join(root, "dist", "mochi-gvm.wasm")] : [] of String
    resolve("MOCHI_GVM_WASM", "gvm_wasm", defaults)
  end

  def js : String?
    if @environment["MOCHI_GVM_JS"]?
      return resolve("MOCHI_GVM_JS", "gvm_js", js_defaults)
    end
    if wasm_override = @environment["MOCHI_GVM_WASM"]?
      sibling = wasm_override.sub(/\.wasm\z/, ".js")
      if File.file?(sibling)
        return File.expand_path(sibling)
      end
      raise setup_error("MOCHI_GVM_WASM override has no sibling runtime JS at #{sibling}; set MOCHI_GVM_JS to the matching file")
    end
    root = gvm_root
    defaults = root ? [File.join(root, "dist", "mochi-gvm.js")] : [] of String
    resolve("MOCHI_GVM_JS", "gvm_js", defaults)
  end

  def loader : String?
    resolve("MOCHI_LOADER", "loader", [File.join(@development_root, "runtime", "mochi-loader.js")])
  end

  def format_host : String?
    host_adapter("mochi-format.js")
  end

  def host_adapter(host : String) : String?
    name = File.basename(host)
    environment_key = if name == "mochi-format.js"
                        "MOCHI_FORMAT_HOST"
                      else
                        "MOCHI_HOST_ADAPTER_#{name.upcase.gsub(/[^A-Z0-9]/, "_")}"
                      end
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
    resolve("MOCHI_GVM_DIR", "gvm_root", defaults, directory: true)
  end

  # Validate all artifacts needed by a standard build before output cleanup or
  # compilation begins. E5 will extend the runtime identity record with the
  # selected fixed-capacity profile; current bundles use manifest schema 3.
  def validate_build_resources! : Nil
    compiler = required_path("MOCHI_COMPILER", "compiler", [File.join(@development_root, "compiler", "mochi")], executable: true)
    required_path("MRBC", "mrbc", mrbc_defaults, executable: true)
    wasm_path = required_path("MOCHI_GVM_WASM", "gvm_wasm", wasm_defaults)
    js_path = js || raise(setup_error("required runtime JS not found; set MOCHI_GVM_JS or run `task install:dev`"))
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
      raise setup_error("compiler resource is missing; run `task build` or `task install:dev`")
    end
    validate_record_identity!({compiler, wasm_path, js_path})
  end

  def validate_runtime_artifacts!(hosts : Array(String) = [] of String) : Nil
    validate_build_resources!
    hosts.each do |host|
      environment_key = host == "mochi-format.js" ? "MOCHI_FORMAT_HOST" : "MOCHI_HOST_ADAPTER_#{File.basename(host).upcase.gsub(/[^A-Z0-9]/, "_")}"
      defaults = [File.join(@development_root, "runtime", File.basename(host))]
      resolve(environment_key, "", defaults) || raise(setup_error("host adapter '#{host}' missing; set #{environment_key} or rerun `task install:dev`"))
    end
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
      "required resource '#{record_key}' not found from #{location}; set #{environment_key} or run `task install:dev`"
    )
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
    raise setup_error("#{source} points to missing #{expected} #{expanded}#{detail}; correct the override or rerun `task install:dev`")
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
      raise setup_error("MOCHI_INSTALL_RECORD points to missing file #{expanded}; reinstall with `task install:dev`")
    end
    parsed = begin
      JSON.parse(File.read(expanded)).as_h
    rescue ex
      raise setup_error("invalid installation record #{expanded}: #{ex.message}; rerun `task install:dev`")
    end
    version = parsed["schema_version"]?.try(&.as_i?)
    unless version == RECORD_SCHEMA_VERSION
      raise setup_error("installation record #{expanded} uses schema #{version || "unknown"}; rerun `task install:dev`")
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
    raise setup_error("installation record #{@record_path} has invalid '#{key}' path; rerun `task install:dev`")
  end

  private def recorded_host_adapter(host : String) : String?
    adapters = @record.try(&.["host_adapters"]?)
    return nil unless adapters
    value = adapters.as_h[host]?
    return nil unless value
    return nil if value.raw.nil?
    value.as_s
  rescue
    raise setup_error("installation record #{@record_path} has invalid host adapter '#{host}'; rerun `task install:dev`")
  end

  private def validate_record_identity!(paths : Tuple(String, String, String)) : Nil
    return unless @record

    owner = record_value("owner")
    unless owner == "mochi-development-install"
      raise setup_error("installation record owner is missing or invalid; reinstall with `task install:dev`")
    end
    profile = record_value("runtime_profile")
    unless profile == "default"
      raise setup_error("installation record is missing a supported runtime profile; rerun `task install:dev:update`") if profile.nil?
      raise setup_error("installed runtime profile '#{profile}' is not supported by this compiler; rebuild and reinstall matching Mochi runtime artifacts")
    end
    fingerprint = record_value("capacity_fingerprint")
    unless fingerprint == CapacityConfig.default.fingerprint
      raise setup_error("installed capacity fingerprint #{fingerprint || "missing"} does not match the default compiler profile; run `task install:dev:update`")
    end
    schema = @record.not_nil!["manifest_schema"]?.try(&.as_i?)
    unless schema == MANIFEST_SCHEMA
      raise setup_error("installed compiler/runtime manifest schema #{schema || "missing"} does not match #{MANIFEST_SCHEMA}; run `task build` and `task install:dev:update`")
    end

    identities = [
      {paths[0], "compiler_sha256"},
      {paths[1], "gvm_wasm_sha256"},
      {paths[2], "gvm_js_sha256"},
      {paths[1].sub(/\.wasm\z/, ".capacity.json"), "gvm_capacity_sha256"},
    ]
    identities.each do |path, key|
      expected = record_value(key)
      raise setup_error("installation record is missing #{key}; rerun `task install:dev:update`") unless expected
      unless expected.matches?(/\A[0-9a-f]{64}\z/)
        raise setup_error("installation record has invalid #{key}; rerun `task install:dev:update`")
      end
      actual = Digest::SHA256.hexdigest(File.read(path))
      next if actual == expected
      label = key.sub("_sha256", "")
      raise setup_error("#{label} does not match installed runtime identity; update the matching artifacts and run `task install:dev:update`")
    end
  end

  private def setup_error(message : String) : String
    "Mochi setup: #{message}"
  end
end
