require "file_utils"
require "json"
require "random"
require "digest/sha256"
require "../../src/tooling/installation_paths"

describe InstallationPaths do
  it "resolves overrides before installed records and handles spaces" do
    root = File.join(Dir.tempdir, "mochi install paths #{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(root)
    checkout = File.join(root, "checkout with spaces")
    prefix = File.join(root, "user prefix")
    FileUtils.mkdir_p(File.join(checkout, "runtime"))
    FileUtils.mkdir_p(File.join(checkout, "e2e", "node_modules"))
    FileUtils.mkdir_p(File.join(checkout, "e2e", "node_modules", "playwright"))
    File.write(File.join(checkout, "e2e", "node_modules", "playwright", "package.json"), "{}")
    FileUtils.mkdir_p(File.join(prefix, "share", "mochi"))
    checkout_loader = File.join(checkout, "runtime", "mochi-loader.js")
    override_loader = File.join(root, "override loader.js")
    record_loader = File.join(root, "record loader.js")
    record_host = File.join(root, "record format host.js")
    override_host = File.join(root, "override format host.js")
    [checkout_loader, override_loader, record_loader, record_host, override_host].each { |path| File.write(path, "loader") }
    record_path = File.join(prefix, "share", "mochi", "install.json")
    File.write(record_path, JSON.build do |json|
      json.object do
        json.field "schema_version", 1
        json.field "loader", record_loader
        json.field "playwright_node_modules", File.join(checkout, "e2e", "node_modules")
        json.field "host_adapters" do
          json.object { json.field "mochi-format.js", record_host }
        end
      end
    end)

    paths = InstallationPaths.new(
      {
        "MOCHI_INSTALL_RECORD" => record_path,
        "MOCHI_LOADER"         => override_loader,
        "MOCHI_FORMAT_HOST"    => override_host,
      },
      checkout
    )
    paths.loader.should eq(override_loader)
    paths.format_host.should eq(override_host)
    paths.playwright_node_modules.should eq(File.join(checkout, "e2e", "node_modules"))
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "fails an invalid explicit override instead of falling through" do
    root = File.join(Dir.tempdir, "mochi install override #{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(root, "runtime"))
    File.write(File.join(root, "runtime", "mochi-loader.js"), "valid")
    paths = InstallationPaths.new({"MOCHI_LOADER" => File.join(root, "missing.js")}, root)

    expect_raises(Exception, /MOCHI_LOADER points to missing file/) { paths.loader }
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "rejects installation records with unsupported runtime profiles" do
    root = File.join(Dir.tempdir, "mochi install profile #{Random.rand(1_000_000)}")
    paths = valid_installation_paths_fixture(root, "custom-capacity")[0]
    expect_raises(Exception, /runtime profile 'custom-capacity' is not supported/) do
      paths.validate_build_resources!
    end
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "rejects an installation record from a different schema version" do
    root = File.join(Dir.tempdir, "mochi install schema #{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(root)
    record = File.join(root, "install.json")
    File.write(record, %({"schema_version":99}))
    expect_raises(Exception, /uses schema 99/) do
      InstallationPaths.new({"MOCHI_INSTALL_RECORD" => record}, root)
    end
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "rejects an installed loader with an incompatible manifest schema" do
    root = File.join(Dir.tempdir, "mochi install manifest #{Random.rand(1_000_000)}")
    paths = valid_installation_paths_fixture(root, "default")[0]
    loader = File.join(root, "checkout", "runtime", "mochi-loader.js")
    File.write(loader, "var MANIFEST_SCHEMA_VERSION = 1;")
    expect_raises(Exception, /does not support bundle schema 3/) do
      paths.validate_build_resources!
    end
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "rejects runtime bytes that do not match the installed capacity profile identity" do
    root = File.join(Dir.tempdir, "mochi install runtime hash #{Random.rand(1_000_000)}")
    paths = valid_installation_paths_fixture(root, "default")[0]
    File.write(File.join(root, "gvm", "dist", "mochi-gvm.wasm"), "\0asm\x01\0\0\0different")
    expect_raises(Exception, /gvm_wasm does not match installed runtime identity/) do
      paths.validate_build_resources!
    end
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "rejects a default runtime with mismatched capacity metadata before compilation" do
    root = File.join(Dir.tempdir, "mochi install capacity profile #{Random.rand(1_000_000)}")
    paths = valid_installation_paths_fixture(root, "default")[0]
    profile = File.join(root, "gvm", "dist", "mochi-gvm.capacity.json")
    File.write(profile, "{}")
    expect_raises(Exception, /default GVM capacity profile mismatch/) do
      paths.validate_build_resources!
    end
  ensure
    FileUtils.rm_rf(root) if root
  end
end

private def valid_installation_paths_fixture(root : String, profile : String) : Tuple(InstallationPaths, String)
  checkout = File.join(root, "checkout")
  prefix = File.join(root, "prefix")
  gvm = File.join(root, "gvm")
  mrbc = File.join(gvm, "build_wasm", "mruby", "src", "build", "mochi-v2-host", "bin", "mrbc")
  compiler = File.join(checkout, "compiler", "mochi")
  wasm = File.join(gvm, "dist", "mochi-gvm.wasm")
  js = File.join(gvm, "dist", "mochi-gvm.js")
  loader = File.join(checkout, "runtime", "mochi-loader.js")
  record = File.join(prefix, "share", "mochi", "install.json")
  [mrbc, compiler, wasm, js, loader, record].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
  File.write(mrbc, "#!/bin/sh\nexit 0\n")
  File.chmod(mrbc, 0o755)
  File.write(compiler, "#!/bin/sh\nexit 0\n")
  File.chmod(compiler, 0o755)
  File.write(wasm, "\0asm\x01\0\0\0")
  File.write(wasm.sub(/\.wasm\z/, ".capacity.json"), CapacityConfig.default.profile_json)
  File.write(js, "var MochiModule = {};")
  File.write(loader, "var MANIFEST_SCHEMA_VERSION = 3;")
  File.write(record, JSON.build do |json|
    json.object do
      json.field "schema_version", 1
      json.field "owner", "mochi-development-install"
      json.field "manifest_schema", 3
      json.field "runtime_profile", profile
      json.field "compiler", compiler
      json.field "compiler_sha256", Digest::SHA256.hexdigest(File.read(compiler))
      json.field "gvm_root", gvm
      json.field "mrbc", mrbc
      json.field "gvm_wasm", wasm
      json.field "gvm_wasm_sha256", Digest::SHA256.hexdigest(File.read(wasm))
      json.field "gvm_js", js
      json.field "gvm_js_sha256", Digest::SHA256.hexdigest(File.read(js))
      profile = File.join(gvm, "dist", "mochi-gvm.capacity.json")
      json.field "gvm_capacity_sha256", Digest::SHA256.hexdigest(File.read(profile))
      json.field "capacity_fingerprint", CapacityConfig.default.fingerprint
      json.field "loader", loader
    end
  end)
  {InstallationPaths.new({"MOCHI_INSTALL_RECORD" => record}, checkout), record}
end
