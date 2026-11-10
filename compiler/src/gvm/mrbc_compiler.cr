require "json"
require "file_utils"
require "../mochi_cmp"
require "../sorbet/type_stripper"
require "./source_preparer"

class MrbcCompiler
  RITE_HEADER    = "RITE0400\u0000\u0000"
  COMPONENTS_DIR = "components"

  getter manifest_path : String?
  getter chi_paths : Array(String)
  getter wasm_path : String?
  getter js_path : String?
  getter loader_path : String?
  getter warnings : Array(String)

  def initialize(
    @mrbc_path : String? = ENV["MRBC"]?,
    @wasm_source : String? = ENV["MOCHI_GVM_WASM"]?,
    @loader_source : String? = ENV["MOCHI_LOADER"]?,
    @js_source : String? = ENV["MOCHI_GVM_JS"]?,
  )
    @manifest_path = nil
    @chi_paths = [] of String
    @wasm_path = nil
    @js_path = nil
    @loader_path = nil
    @warnings = [] of String
  end

  def compile(components : Array(MochiComponent), output_dir : String) : Nil
    @chi_paths.clear
    @warnings.clear
    Dir.mkdir_p(output_dir)
    components_dir = File.join(output_dir, COMPONENTS_DIR)
    Dir.mkdir_p(components_dir)

    sorted_components = components.sort_by { |component| component.manifest.tag_name }
    results = Channel(Tuple(String, String?, String?)).new(sorted_components.size)
    chi_paths_by_tag = {} of String => String

    sorted_components.each do |component|
      spawn do
        begin
          chi_path = compile_component(component, components_dir)
          results.send({component.manifest.tag_name, chi_path, nil})
        rescue ex
          results.send({component.manifest.tag_name, nil, ex.message})
        end
      end
    end

    errors = [] of String
    sorted_components.size.times do
      tag_name, chi_path, error = results.receive
      if error
        errors << "#{tag_name}: #{error}"
      elsif chi_path
        chi_paths_by_tag[tag_name] = chi_path
      end
    end

    unless errors.empty?
      raise "mrbc failed:\n#{errors.join("\n")}"
    end

    @chi_paths = sorted_components.compact_map { |component| chi_paths_by_tag[component.manifest.tag_name]? }
    @wasm_path = copy_asset(resolved_wasm_source, output_dir, "mochi-gvm.wasm")
    @js_path = copy_asset(resolved_js_source, output_dir, "mochi-gvm.js")
    @loader_path = copy_asset(resolved_loader_source, output_dir, "mochi-loader.js")

    if @wasm_path.nil?
      @warnings << "mochi-gvm.wasm not found; set MOCHI_GVM_WASM or place ../mochi-gvm/dist/mochi-gvm.wasm"
    end
    if @js_path.nil?
      @warnings << "mochi-gvm.js not found; set MOCHI_GVM_JS or place ../mochi-gvm/dist/mochi-gvm.js"
    end
    if @loader_path.nil?
      @warnings << "mochi-loader.js not found; set MOCHI_LOADER or add runtime/mochi-loader.js"
    end

    @manifest_path = File.join(output_dir, "mochi-manifest.json")
    File.write(@manifest_path.not_nil!, build_manifest_json(sorted_components))
  end

  private def compile_component(component : MochiComponent, components_dir : String) : String
    manifest = component.manifest
    source = SorbetTypeStripper.strip(component.ruby_code)
    source = GvmSourcePreparer.strip_class_ivars(source)

    ruby_file = File.tempfile("mochi-#{safe_name(manifest.tag_name)}", ".rb")
    mrb_file = File.tempfile("mochi-#{safe_name(manifest.tag_name)}", ".mrb")

    begin
      ruby_file.print(source)
      ruby_file.close
      mrb_file.close

      run_mrbc(ruby_file.path, mrb_file.path)
      bytecode = File.read(mrb_file.path).to_slice
      body = strip_rite_header(bytecode, manifest.tag_name)

      chi_path = File.join(components_dir, manifest.chi_file)
      File.write(chi_path, body)
      chi_path
    ensure
      File.delete(ruby_file.path) if File.exists?(ruby_file.path)
      File.delete(mrb_file.path) if File.exists?(mrb_file.path)
    end
  end

  private def run_mrbc(ruby_path : String, output_path : String) : Nil
    mrbc = resolved_mrbc_path
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(
      mrbc,
      ["-o", output_path, ruby_path],
      output: stdout,
      error: stderr
    )

    return if status.success?

    message = stderr.to_s
    message = stdout.to_s if message.empty?
    raise "mrbc exited with #{status.exit_code}: #{message.strip}"
  end

  private def strip_rite_header(bytecode : Bytes, tag_name : String) : Bytes
    header_size = RITE_HEADER.bytesize
    unless bytecode.size > header_size && bytecode[0, header_size] == RITE_HEADER.to_slice
      raise "invalid RITE header for #{tag_name}"
    end

    bytecode[header_size, bytecode.size - header_size]
  end

  private def resolved_mrbc_path : String
    @mrbc_path || self.class.find_mrbc || raise "mrbc not found; set MRBC to the mruby compiler path"
  end

  private def resolved_wasm_source : String?
    @wasm_source || self.class.find_wasm
  end

  private def resolved_js_source : String?
    return @js_source if @js_source

    if wasm_source = @wasm_source
      sibling = wasm_source.sub(/\.wasm\z/, ".js")
      return sibling if File.file?(sibling)
    end

    self.class.find_js
  end

  private def resolved_loader_source : String?
    @loader_source || self.class.find_loader
  end

  def self.find_mrbc : String?
    Process.find_executable("mrbc") || first_existing_executable([
      File.join(Dir.current, "build_wasm", "mruby", "src", "build", "host", "bin", "mrbc"),
      File.join(Dir.current, "build_wasm", "mruby", "src", "build", "mochi-v2-host", "bin", "mrbc"),
      File.join(Dir.current, "..", "build_wasm", "mruby", "src", "build", "host", "bin", "mrbc"),
      File.join(Dir.current, "..", "build_wasm", "mruby", "src", "build", "mochi-v2-host", "bin", "mrbc"),
    ])
  end

  def self.find_wasm : String?
    candidates = [
      File.join(Dir.current, "..", "mochi-gvm", "dist", "mochi-gvm.wasm"),
      File.join(Dir.current, "..", "..", "mochi-gvm", "dist", "mochi-gvm.wasm"),
      File.join(Dir.current, "mochi-gvm", "dist", "mochi-gvm.wasm"),
      File.join(Dir.current, "dist", "mochi-gvm.wasm"),
    ]

    first_existing_file(candidates)
  end

  def self.find_js : String?
    candidates = [
      File.join(Dir.current, "..", "mochi-gvm", "dist", "mochi-gvm.js"),
      File.join(Dir.current, "..", "..", "mochi-gvm", "dist", "mochi-gvm.js"),
      File.join(Dir.current, "mochi-gvm", "dist", "mochi-gvm.js"),
      File.join(Dir.current, "dist", "mochi-gvm.js"),
    ]

    first_existing_file(candidates)
  end

  def self.find_loader : String?
    candidates = [
      File.join(Dir.current, "runtime", "mochi-loader.js"),
      File.join(Dir.current, "..", "runtime", "mochi-loader.js"),
      File.join(Dir.current, "..", "..", "runtime", "mochi-loader.js"),
      File.join(Dir.current, "..", "mochi-gvm", "runtime", "mochi-loader.js"),
      File.join(Dir.current, "..", "..", "mochi-gvm", "runtime", "mochi-loader.js"),
    ]

    first_existing_file(candidates)
  end

  private def self.first_existing_file(candidates : Array(String)) : String?
    candidates.find { |path| File.file?(path) }
  end

  private def self.first_existing_executable(candidates : Array(String)) : String?
    candidates.find { |path| File.info?(path).try(&.permissions.owner_execute?) }
  end

  private def copy_asset(source : String?, output_dir : String, filename : String) : String?
    return nil unless source && File.file?(source)

    destination = File.join(output_dir, filename)
    FileUtils.cp(source, destination)
    destination
  end

  private def build_manifest_json(components : Array(MochiComponent)) : String
    JSON.build do |json|
      json.object do
        json.field "components" do
          json.array do
            components.each do |component|
              write_component(json, component.manifest)
            end
          end
        end
        json.field "wasm_file", @wasm_path ? File.basename(@wasm_path.not_nil!) : nil
        json.field "js_file", @js_path ? File.basename(@js_path.not_nil!) : nil
        json.field "loader_file", @loader_path ? File.basename(@loader_path.not_nil!) : nil
      end
    end
  end

  private def write_component(json : JSON::Builder, manifest : ComponentManifest) : Nil
    json.object do
      json.field "tag_name", manifest.tag_name
      json.field "class_name", manifest.class_name
      json.field "chi_file", manifest.chi_file
      json.field "html_template", manifest.html_template
      json.field "css", manifest.css

      write_bindings(json, manifest.bindings)
      write_events(json, manifest.events)
    end
  end

  private def write_bindings(json : JSON::Builder, bindings : Array(BindingDescriptor)) : Nil
    json.field "bindings" do
      json.array do
        bindings.each { |binding| write_binding(json, binding) }
      end
    end
  end

  private def write_binding(json : JSON::Builder, binding : BindingDescriptor) : Nil
    json.object do
      json.field "id", binding.id
      json.field "path" do
        json.array do
          binding.path.each { |index| json.number(index) }
        end
      end
      json.field "kind", binding.kind
      json.field "attr_name", binding.attr_name
      json.field "template_text", binding.template_text
      json.field "getter_sym", binding.getter_sym
      json.field "setter_sym", binding.setter_sym

      unless binding.branches.empty?
        json.field "branches" do
          json.array do
            binding.branches.each do |branch|
              json.object do
                json.field "html_template", branch.html_template
                write_bindings(json, branch.bindings)
                write_events(json, branch.events)
              end
            end
          end
        end
      end
    end
  end

  private def write_events(json : JSON::Builder, events : Array(EventDescriptor)) : Nil
    json.field "events" do
      json.array do
        events.each do |event|
          json.object do
            json.field "path" do
              json.array do
                event.path.each { |index| json.number(index) }
              end
            end
            json.field "event", event.event
            json.field "method_sym", event.method_sym
            json.field "args" do
              json.array do
                event.args.each do |arg|
                  json.object { arg.write_fields(json) }
                end
              end
            end
          end
        end
      end
    end
  end

  private def safe_name(name : String) : String
    name.gsub(/[^a-zA-Z0-9_-]/, "_")
  end
end
