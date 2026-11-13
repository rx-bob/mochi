require "json"
require "digest/sha256"

# Fixed limits that are compiled into one Mochi GVM artifact. The JSON form is
# deliberately small and versioned: it is a build input, not runtime tuning.
struct CapacityConfig
  SCHEMA_VERSION = 1
  DEFAULTS       = {
    "scratch_bytes"                 => 131_072_i64,
    "scratch_objects"               => 2_048_i64,
    "scratch_ivars"                 => 2_048_i64,
    "scratch_slots"                 => 4_096_i64,
    "state_classes"                 => 512_i64,
    "state_objects"                 => 32_768_i64,
    "state_ivars"                   => 65_536_i64,
    "state_slots"                   => 131_072_i64,
    "state_bytes"                   => 8_388_608_i64,
    "state_components"              => 1_024_i64,
    "promotion_depth"               => 32_i64,
    "bindings"                      => 2_048_i64,
    "abi_call_args"                 => 8_i64,
    "abi_bytecode_bytes"            => 4_194_304_i64,
    "ivars_per_object"              => 256_i64,
    "host_patch_bytes"              => 65_536_i64,
    "host_fetch_envelope_bytes"     => 65_536_i64,
    "host_emit_envelope_bytes"      => 16_384_i64,
    "host_event_args_bytes"         => 8_192_i64,
    "host_command_bytes"            => 8_192_i64,
    "host_network_pending_requests" => 256_i64,
    "host_network_response_bytes"   => 5_000_i64,
    "host_network_buffer_bytes"     => 4_194_304_i64,
    "host_format_cache_entries"     => 32_i64,
    "host_event_queue_entries"      => 256_i64,
    "host_event_queue_bytes"        => 2_097_152_i64,
    "host_drag_payload_bytes"       => 1_024_i64,
    "host_file_handles"             => 128_i64,
    "host_file_readers"             => 4_i64,
    "host_file_chunk_bytes"         => 8_192_i64,
    "host_file_whole_read_bytes"    => 48_000_i64,
    "host_file_buffer_bytes"        => 262_144_i64,
    "goose_stack_bytes"             => 65_536_i64,
    "goose_stack_regions"           => 40_i64,
    "goose_guard_bytes"             => 1_048_576_i64,
    "wasm_stack_bytes"              => 1_048_576_i64,
    "memory_bytes"                  => 100_663_296_i64,
  }

  getter values : Hash(String, Int64)
  getter fingerprint : String

  def initialize(@values : Hash(String, Int64))
    validate!
    @fingerprint = Digest::SHA256.hexdigest(canonical_json)
  end

  def self.default : CapacityConfig
    new(DEFAULTS.dup)
  end

  def self.read(path : String) : CapacityConfig
    parsed = JSON.parse(File.read(path)).as_h
    unknown_top_level = parsed.keys - ["schema_version", "capacities"]
    raise "unknown capacity config field '#{unknown_top_level.first}'" unless unknown_top_level.empty?
    version = parsed["schema_version"]?.try(&.as_i?)
    raise "capacity config schema_version must be #{SCHEMA_VERSION}" unless version == SCHEMA_VERSION
    raw = parsed["capacities"]?.try(&.as_h?) || raise "capacity config must contain a capacities object"
    values = DEFAULTS.dup
    raw.each do |key, value|
      raise "unknown capacity '#{key}'" unless DEFAULTS.has_key?(key)
      values[key] = value.as_i64
    rescue TypeCastError
      raise "capacity '#{key}' must be an integer"
    end
    new(values)
  rescue ex : JSON::ParseException
    raise "invalid capacity config: #{ex.message}"
  rescue ex : KeyError
    raise "invalid capacity config: #{ex.message}"
  end

  def canonical_json : String
    JSON.build do |json|
      json.object do
        json.field "schema_version", SCHEMA_VERSION
        json.field "capacities" do
          json.object do
            DEFAULTS.keys.sort.each { |key| json.field key, @values[key] }
          end
        end
      end
    end
  end

  def profile_json : String
    JSON.build do |json|
      json.object do
        json.field "schema_version", SCHEMA_VERSION
        json.field "fingerprint", @fingerprint
        json.field "memory_bytes", @values["memory_bytes"]
        json.field "capacities" do
          json.object do
            DEFAULTS.keys.sort.each { |key| json.field key, @values[key] }
          end
        end
      end
    end
  end

  def to_json(json : JSON::Builder) : Nil
    json.raw(canonical_json)
  end

  def [](name : String) : Int64
    @values[name]
  end

  def validate! : Nil
    @values.each do |name, value|
      raise "capacity '#{name}' must be positive" unless value > 0
      raise "capacity '#{name}' exceeds the supported 32-bit limit" if value > Int32::MAX
    end
    {"scratch_objects", "scratch_ivars", "scratch_slots", "scratch_bytes"}.each do |name|
      raise "capacity '#{name}' must be at least 4" if @values[name] < 4
    end
    {"state_objects" => 4_096_i64, "state_ivars" => 4_096_i64,
     "state_slots" => 8_192_i64, "state_bytes" => 262_144_i64}.each do |name, reserve|
      raise "capacity '#{name}' must exceed the GC reserve #{reserve}" if @values[name] <= reserve
    end
    raise "capacity 'state_objects' exceeds the 15-bit arena handle limit of 32768" if @values["state_objects"] > 32_768
    raise "capacity 'state_classes' must not exceed 512" if @values["state_classes"] > 512
    raise "capacity 'state_components' must not exceed 1024" if @values["state_components"] > 1_024
    raise "capacity 'promotion_depth' must not exceed 256" if @values["promotion_depth"] > 256
    raise "capacity 'abi_call_args' is fixed at 8 by the runtime ABI" unless @values["abi_call_args"] == 8
    raise "capacity 'ivars_per_object' is fixed at 256 by the runtime ivar mask" unless @values["ivars_per_object"] == 256
    raise "capacity 'goose_stack_regions' is fixed at 40 by the compiled VM" unless @values["goose_stack_regions"] == 40
    raise "capacity 'goose_guard_bytes' is fixed at 1048576 by the Goose runtime" unless @values["goose_guard_bytes"] == 1_048_576
    raise "capacity 'goose_stack_bytes' must be at least 65536" if @values["goose_stack_bytes"] < 65_536
    raise "capacity 'memory_bytes' must be a multiple of 65536" unless @values["memory_bytes"] % 65_536 == 0
    {"goose_stack_bytes", "wasm_stack_bytes"}.each do |name|
      raise "capacity '#{name}' must be a multiple of 65536" unless @values[name] % 65_536 == 0
    end
    minimum = minimum_memory_bytes
    raise "capacity 'memory_bytes' (#{@values["memory_bytes"]}) is below the arena minimum (#{minimum})" if @values["memory_bytes"] < minimum
    validate_host_capacities!
  end

  def validate_host_capacities! : Nil
    {
      "host_patch_bytes"            => 1_024_i64,
      "host_fetch_envelope_bytes"   => 1_024_i64,
      "host_emit_envelope_bytes"    => 1_024_i64,
      "host_event_args_bytes"       => 512_i64,
      "host_command_bytes"          => 512_i64,
      "host_network_response_bytes" => 1_i64,
      "host_network_buffer_bytes"   => 1_i64,
      "host_event_queue_bytes"      => 1_i64,
      "host_drag_payload_bytes"     => 1_i64,
      "host_file_chunk_bytes"       => 1_i64,
      "host_file_readers"           => 1_i64,
      "host_file_whole_read_bytes"  => 1_i64,
      "host_file_buffer_bytes"      => 1_i64,
    }.each do |name, minimum|
      raise "capacity '#{name}' must be at least #{minimum}" if @values[name] < minimum
    end
    raise "capacity 'host_network_pending_requests' exceeds the 16-bit request table limit" if @values["host_network_pending_requests"] > 65_535
    raise "capacity 'host_format_cache_entries' exceeds the 16-bit cache limit" if @values["host_format_cache_entries"] > 65_535
    raise "capacity 'host_event_queue_entries' exceeds the 16-bit queue limit" if @values["host_event_queue_entries"] > 65_535
    raise "capacity 'host_file_handles' exceeds the 16-bit handle limit" if @values["host_file_handles"] > 65_535
    raise "capacity 'host_file_readers' exceeds the 16-bit reader limit" if @values["host_file_readers"] > 65_535

    fetch_envelope = @values["host_fetch_envelope_bytes"]
    # The envelope contains the escaped response text and, for JSON responses,
    # a parsed value serialized again alongside it. Reserve 12x plus metadata.
    response_wire_bytes = @values["host_network_response_bytes"] * 12 + 256
    raise "network response capacity exceeds the fetch envelope after JSON envelope expansion" if response_wire_bytes > fetch_envelope
    chunk_wire_bytes = ((@values["host_file_chunk_bytes"] + 2) // 3) * 4 + 256
    raise "file chunk capacity exceeds the fetch envelope after base64 expansion" if chunk_wire_bytes > fetch_envelope
    raise "file chunk and decoded binary value exceed scratch_bytes" if @values["host_file_chunk_bytes"] + chunk_wire_bytes > @values["scratch_bytes"]
    whole_wire_bytes = ((@values["host_file_whole_read_bytes"] + 2) // 3) * 4 + 256
    raise "whole-file capacity exceeds the fetch envelope after base64 expansion" if whole_wire_bytes > fetch_envelope
    file_chunk_reservation = @values["host_file_readers"] *
                             (@values["host_file_chunk_bytes"] + chunk_wire_bytes)
    raise "concurrent file chunks and envelopes exceed host_file_buffer_bytes" if file_chunk_reservation > @values["host_file_buffer_bytes"]
    whole_read_reservation = @values["host_file_whole_read_bytes"] +
                             @values["host_file_chunk_bytes"] + whole_wire_bytes +
                             (@values["host_file_readers"] - 1) *
                             (@values["host_file_chunk_bytes"] + chunk_wire_bytes)
    raise "whole-file read and concurrent chunks exceed host_file_buffer_bytes" if whole_read_reservation > @values["host_file_buffer_bytes"]
    drag_wire_bytes = @values["host_drag_payload_bytes"] * 6 + 256
    raise "drag payload capacity exceeds host_event_args_bytes after JSON escaping" if drag_wire_bytes > @values["host_event_args_bytes"]
    event_queue_bytes = @values["host_event_queue_entries"] * (@values["host_drag_payload_bytes"] * 6 + 64)
    raise "event queue capacity exceeds host_event_queue_bytes" if event_queue_bytes > @values["host_event_queue_bytes"]
    network_reservation = @values["host_network_pending_requests"] * @values["host_network_response_bytes"]
    raise "concurrent network responses exceed host_network_buffer_bytes" if network_reservation > @values["host_network_buffer_bytes"]
  end

  def minimum_memory_bytes : Int64
    # Conservative inline storage estimate, plus the existing VM and C stack.
    scratch = @values["scratch_bytes"] + @values["scratch_objects"] * 128 +
              @values["scratch_ivars"] * 32 + @values["scratch_slots"] * 40
    # Persistent arenas and their free lists/mark worklists have inline backing
    # at their declared limits. Include one extra coalescing byte-range slot.
    state = @values["state_bytes"] + @values["state_objects"] * (128 + 8 + 16 + 4 + 8) +
            @values["state_ivars"] * (32 + 8) + @values["state_slots"] * (40 + 8) + 16
    stack = @values["goose_stack_regions"] *
            (@values["goose_stack_bytes"] + @values["goose_guard_bytes"]) +
            @values["wasm_stack_bytes"]
    bridge_buffers = @values["host_patch_bytes"] + @values["host_fetch_envelope_bytes"] * 3 +
                     @values["host_emit_envelope_bytes"] + @values["host_event_args_bytes"] +
                     @values["host_command_bytes"] * 2 + 262_144
    abi_and_bridge = @values["abi_bytecode_bytes"] + bridge_buffers
    # Cache entries, method descriptors and flattened root symbols. These are
    # bounded metadata, outside the ordinary persistent object/slot arenas.
    computed = @values["bindings"] * 64 + 4_096 * (24 + 256 * 4)
    initial_heap = 4_194_304_i64
    ((scratch + state + stack + abi_and_bridge + computed + initial_heap + 65_535) // 65_536) * 65_536
  end
end
