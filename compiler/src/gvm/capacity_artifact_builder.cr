require "file_utils"
require "path"
require "random"
require "time"
require "digest/sha256"
require "../tooling/installation_paths"
require "./capacity_config"

# Builds each custom VM profile from an isolated source copy. The shared GVM
# checkout is read-only; cache identity includes runtime sources and profile.
class CapacityArtifactBuilder
  record Artifacts, wasm : String, js : String, profile : String

  def initialize(@gvm_root : String, @config : CapacityConfig)
  end

  def build : Artifacts
    source_id = source_fingerprint
    cache_root = File.join(Path.home, ".cache", "mochi", "gvm-capacities")
    cache_dir = File.join(cache_root, "#{source_id}-#{@config.fingerprint}")
    wasm = File.join(cache_dir, "dist", "mochi-gvm.wasm")
    js = File.join(cache_dir, "dist", "mochi-gvm.js")
    profile = File.join(cache_dir, "dist", "mochi-gvm.capacity.json")
    return Artifacts.new(wasm, js, profile) if File.file?(wasm) && File.file?(js) && File.file?(profile)

    FileUtils.mkdir_p(cache_root)
    lock = cache_dir + ".lock"
    acquire_lock(lock)
    begin
      return Artifacts.new(wasm, js, profile) if File.file?(wasm) && File.file?(js) && File.file?(profile)
      work = File.join(cache_root, ".build-#{Process.pid}-#{Random::Secure.hex(8)}")
      begin
        FileUtils.mkdir_p(work)
        FileUtils.cp_r(File.join(@gvm_root, "src"), work)
        FileUtils.cp_r(File.join(@gvm_root, "scripts"), work)
        write_profile(work)
        status = Process.run(
          "goose",
          ["run", "scripts/build_wasm.goose"],
          chdir: work,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit
        )
        raise "Mochi capacity build failed with exit status #{status.exit_code}" unless status.success?
        unless File.file?(File.join(work, "dist", "mochi-gvm.wasm")) &&
               File.file?(File.join(work, "dist", "mochi-gvm.js")) &&
               File.file?(File.join(work, "dist", "mochi-gvm.capacity.json"))
          raise "Mochi capacity build completed without runtime artifacts"
        end
        FileUtils.mkdir_p(cache_dir)
        FileUtils.mv(File.join(work, "dist"), File.join(cache_dir, "dist"))
      ensure
        FileUtils.rm_rf(work) if Dir.exists?(work)
      end
    ensure
      FileUtils.rm_rf(lock)
    end
    Artifacts.new(wasm, js, profile)
  end

  private def acquire_lock(path : String) : Nil
    deadline = Time.instant + 5.minutes
    loop do
      begin
        Dir.mkdir(path)
        return
      rescue ex : Exception
        raise ex unless Dir.exists?(path)
        raise "timed out waiting for capacity artifact build lock #{path}" if Time.instant >= deadline
        sleep 100.milliseconds
      end
    end
  end

  private def source_fingerprint : String
    digest = Digest::SHA256.new
    paths = (Dir.glob(File.join(@gvm_root, "src", "**", "*.goose")) +
             Dir.glob(File.join(@gvm_root, "src", "**", "*.c")) +
             Dir.glob(File.join(@gvm_root, "src", "**", "*.h")) +
             Dir.glob(File.join(@gvm_root, "scripts", "*"))).select { |path| File.file?(path) }.sort
    paths.each do |path|
      relative = path.sub(@gvm_root + "/", "")
      digest.update(relative)
      digest.update("\0")
      digest.update(File.read(path))
      digest.update("\0")
    end
    {"goose", "emcc", "wasm-opt"}.each do |tool|
      process = Process.new(tool, ["--version"], output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
      digest.update(tool)
      # Some toolchains emit one-time cache or environment diagnostics to
      # stderr (notably emcc on its first run). Keep those out of the cache
      # identity; only the stable version output describes the build input.
      digest.update(process.output.gets_to_end)
      process.error.gets_to_end
      status = process.wait
      raise "Mochi capacity build requires #{tool} --version to succeed" unless status.success?
    rescue IO::Error
      raise "Mochi capacity build requires #{tool} on PATH"
    end
    digest.final.hexstring
  end

  private def write_profile(work : String) : Nil
    config_module = String.build do |source|
      source << "// Generated for capacity profile " << @config.fingerprint << ".\n"
      source << "namespace vm;\n\n"
      goose_names = {
        "scratch_bytes"            => "SCRATCH_CAPACITY_BYTES",
        "scratch_objects"          => "SCRATCH_CAPACITY_OBJECTS",
        "scratch_ivars"            => "SCRATCH_CAPACITY_IVARS",
        "scratch_slots"            => "SCRATCH_CAPACITY_SLOTS",
        "state_classes"            => "MAX_STATE_CLASSES",
        "state_objects"            => "MAX_STATE_OBJECTS",
        "state_ivars"              => "MAX_STATE_IVARS",
        "state_slots"              => "MAX_STATE_SLOTS",
        "state_bytes"              => "MAX_STATE_BYTES",
        "state_components"         => "MAX_STATE_COMPONENTS",
        "promotion_depth"          => "MAX_PROMOTION_DEPTH",
        "bindings"                 => "MAX_BINDINGS",
        "abi_call_args"            => "ABI_MAX_CALL_ARGS",
        "abi_bytecode_bytes"       => "ABI_MAX_BYTECODE",
        "host_emit_envelope_bytes" => "HOST_OUTBOX_CAPACITY",
      }
      goose_names.each do |field, name|
        source << "let " << name << " = " << @config[field].to_s << ";\n"
      end
    end
    File.write(File.join(work, "src", "gvm", "capacity_config.goose"), config_module)
    host_macros = {
      "host_patch_bytes"          => "MOCHI_PATCH_CAPACITY",
      "host_fetch_envelope_bytes" => "MOCHI_FETCH_CAPACITY",
      "host_emit_envelope_bytes"  => "MOCHI_EMIT_CAPACITY",
      "host_event_args_bytes"     => "MOCHI_EVENT_ARGS_CAPACITY",
      "host_command_bytes"        => "MOCHI_HOST_CAPACITY",
    }
    profile_header = String.build do |header|
      header << "#ifndef MOCHI_CAPACITY_PROFILE_H\n#define MOCHI_CAPACITY_PROFILE_H\n"
      header << "#define MOCHI_CAPACITY_FINGERPRINT \"#{@config.fingerprint}\"\n"
      host_macros.each do |field, macro_name|
        header << "#define " << macro_name << " " << @config[field].to_s << "\n"
      end
      header << "#define MOCHI_CAPACITY_PROFILE_JSON "
      header << JSON.build { |json| json.string(@config.profile_json) } << "\n#endif\n"
    end
    File.write(
      File.join(work, "src", "gvm", "include", "mochi_capacity_profile.h"),
      profile_header
    )
    build_script = File.read(File.join(work, "scripts", "build_wasm.goose"))
    build_script = build_script.gsub("100663296", @config["memory_bytes"].to_s)
    build_script = build_script.gsub("64K", "#{@config["goose_stack_bytes"] // 1024}K")
    build_script = build_script.gsub("1048576", @config["wasm_stack_bytes"].to_s)
    File.write(File.join(work, "scripts", "build_wasm.goose"), build_script)
  end
end
