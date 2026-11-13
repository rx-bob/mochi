require "spec"
require "json"
require "file_utils"
require "digest/sha256"
require "../../src/gvm/capacity_config"
require "../../src/gvm/capacity_artifact_builder"

describe CapacityConfig do
  it "preserves current arena bounds as the reproducible default profile" do
    first = CapacityConfig.default
    second = CapacityConfig.new(CapacityConfig::DEFAULTS.dup)

    first.values.should eq(CapacityConfig::DEFAULTS)
    first.fingerprint.should eq("8b48ea60102176d9c990ae775ae77eb368dcbbe43cb0638708f8383fe12d8731")
    first.fingerprint.should eq(second.fingerprint)
  end

  it "normalizes omitted defaults and rejects invalid or unsupported limits" do
    root = File.join(Dir.tempdir, "mochi capacity config #{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(root)
    partial = File.join(root, "partial.json")
    File.write(partial, %({"schema_version":1,"capacities":{"state_objects":16384}}))
    normalized = CapacityConfig.read(partial)
    normalized["state_objects"].should eq(16_384)
    normalized["state_bytes"].should eq(CapacityConfig.default["state_bytes"])

    invalid = File.join(root, "invalid.json")
    File.write(invalid, %({"schema_version":1,"capacities":{"state_objects":32769}}))
    expect_raises(Exception, /15-bit arena handle limit/) { CapacityConfig.read(invalid) }

    File.write(invalid, %({"schema_version":1,"capacities":{"abi_call_args":9}}))
    expect_raises(Exception, /fixed at 8/) { CapacityConfig.read(invalid) }

    File.write(invalid, %({"schema_version":1,"capacities":{"host_network_response_bytes":12000}}))
    expect_raises(Exception, /network response capacity exceeds the fetch envelope/) {
      CapacityConfig.read(invalid)
    }

    File.write(invalid, %({"schema_version":1,"capacities":{"host_file_readers":64}}))
    expect_raises(Exception, /concurrent file chunks and envelopes exceed host_file_buffer_bytes/) {
      CapacityConfig.read(invalid)
    }

    File.write(invalid, %({"schema_version":1,"capacities":{"host_event_queue_bytes":500000}}))
    expect_raises(Exception, /event queue capacity exceeds host_event_queue_bytes/) {
      CapacityConfig.read(invalid)
    }
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "accounts for wire metadata and every concurrent reservation" do
    {
      "host_network_response_bytes" => {5_441_i64, /JSON envelope expansion/},
      "host_file_chunk_bytes"       => {48_961_i64, /base64 expansion/},
      "host_file_readers"           => {0_i64, /host_file_readers.*positive/},
      "scratch_bytes"               => {16_384_i64, /file chunk and decoded binary value/},
      "host_file_whole_read_bytes"  => {48_961_i64, /base64 expansion/},
      "host_file_buffer_bytes"      => {32_767_i64, /concurrent file chunks/},
      "host_network_buffer_bytes"   => {1_279_999_i64, /concurrent network responses/},
      "host_drag_payload_bytes"     => {1_323_i64, /JSON escaping/},
    }.each do |name, boundary|
      values = CapacityConfig::DEFAULTS.dup
      values[name] = boundary[0]
      expect_raises(Exception, boundary[1]) { CapacityConfig.new(values) }
    end

    values = CapacityConfig::DEFAULTS.dup
    values["host_network_response_bytes"] = 5_440
    values["host_network_buffer_bytes"] = 256 * 5_440
    values["host_file_readers"] = 1
    values["host_file_chunk_bytes"] = 48_960
    values["host_file_whole_read_bytes"] = 48_960
    values["host_file_buffer_bytes"] = 48_960 + 48_960 + 65_536
    CapacityConfig.new(values)["host_file_buffer_bytes"].should eq(163_456)
  end
end

describe CapacityArtifactBuilder do
  it "builds distinct bounded runtimes whose embedded profiles match their compiled limits" do
    gvm_root = ENV["MOCHI_GVM_DIR"]? || File.expand_path("../../../../mochi-gvm", __DIR__)
    profiles = [small_capacity_config(8_192, 1_048_576), small_capacity_config(16_384, 2_097_152)]
    source_module = File.join(gvm_root, "src", "gvm", "capacity_config.goose")
    original_source = Digest::SHA256.hexdigest(File.read(source_module))
    results = Channel(Tuple(CapacityConfig, CapacityArtifactBuilder::Artifacts)).new
    profiles.each do |config|
      spawn do
        results.send({config, CapacityArtifactBuilder.new(gvm_root, config).build})
      end
    end
    built = Array.new(profiles.size) { results.receive }
    built.each do |config, artifacts|
      output = instantiate_runtime(artifacts.js, config)
      profile = JSON.parse(output).as_h
      profile["fingerprint"].as_s.should eq(config.fingerprint)
      profile["capacities"]["state_objects"].as_i.should eq(config["state_objects"])
      profile["capacities"]["state_bytes"].as_i.should eq(config["state_bytes"])
      generated = File.read(File.join(File.dirname(artifacts.wasm), "goose_vm.c"))
      regions = generated.match(/gs_rt_init\(argc, argv, \d+, (\d+),/).not_nil![1].to_i
      # Smaller profiles can let Goose eliminate temporary storage regions;
      # the fixed accounting bound must cover every generated artifact.
      regions.should be <= config["goose_stack_regions"]
    end
    built[0][1].wasm.should_not eq(built[1][1].wasm)
    first_artifacts = built.find { |config, _| config.fingerprint == profiles.first.fingerprint }.not_nil![1]
    CapacityArtifactBuilder.new(gvm_root, profiles.first).build.wasm.should eq(first_artifacts.wasm)
    Digest::SHA256.hexdigest(File.read(source_module)).should eq(original_source)
  end
end

private def small_capacity_config(state_objects : Int64, state_bytes : Int64) : CapacityConfig
  values = CapacityConfig::DEFAULTS.dup
  values["scratch_bytes"] = 65_536
  values["scratch_objects"] = 512
  values["scratch_ivars"] = 512
  values["scratch_slots"] = 1_024
  values["state_objects"] = state_objects
  values["state_ivars"] = state_objects
  values["state_slots"] = state_objects * 2
  values["state_bytes"] = state_bytes
  values["abi_bytecode_bytes"] = 1_048_576
  values["memory_bytes"] = 100_663_296
  CapacityConfig.new(values)
end

private def instantiate_runtime(js_path : String, config : CapacityConfig) : String
  script = <<-JS
    const create = require(process.argv[1]);
    create().then((module) => {
      const text = module.UTF8ToString(module._mochi_capacity_profile());
      const profile = JSON.parse(text);
      if (profile.fingerprint !== process.argv[2]) process.exit(2);
      if (module._mochi_init_runtime() !== 0) process.exit(3);
      process.stdout.write(text);
    }).catch((error) => { console.error(error); process.exit(4); });
  JS
  process = Process.new(
    "node",
    ["-e", script, js_path, config.fingerprint],
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Pipe
  )
  output = process.output.gets_to_end
  error = process.error.gets_to_end
  status = process.wait
  raise "capacity runtime fixture failed: #{error}" unless status.success?
  output
end
