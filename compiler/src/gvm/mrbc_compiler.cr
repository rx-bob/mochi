require "json"
require "file_utils"
require "digest/sha1"
require "../mochi_cmp"
require "../sorbet/type_stripper"
require "../webcomponents/resource_manifest"
require "./package_graph"
require "./source_preparer"
require "./rite_verifier"

class MrbcCompiler
  RITE_HEADER    = "RITE0400\u0000\u0000"
  COMPONENTS_DIR = "components"

  getter manifest_path : String?
  getter chi_paths : Array(String)
  getter helper_chi_paths : Array(String)
  getter ruby_package_paths : Array(String)
  getter prelude_path : String?
  getter wasm_path : String?
  getter js_path : String?
  getter loader_path : String?
  getter format_host_path : String?
  getter package_graph : MochiPackaging::PackageGraph?
  getter warnings : Array(String)

  def initialize(
    @mrbc_path : String? = ENV["MRBC"]?,
    @wasm_source : String? = ENV["MOCHI_GVM_WASM"]?,
    @loader_source : String? = ENV["MOCHI_LOADER"]?,
    @js_source : String? = ENV["MOCHI_GVM_JS"]?,
    @format_host_source : String? = ENV["MOCHI_FORMAT_HOST"]?,
  )
    @manifest_path = nil
    @chi_paths = [] of String
    @helper_chi_paths = [] of String
    @ruby_package_paths = [] of String
    @prelude_path = nil
    @wasm_path = nil
    @js_path = nil
    @loader_path = nil
    @format_host_path = nil
    @package_graph = nil
    @warnings = [] of String
  end

  def compile(
    components : Array(MochiComponent),
    output_dir : String,
    prelude_code : String = "",
    helpers : Array(HelperUnit) = [] of HelperUnit,
    resources : Array(PackageResource) = [] of PackageResource,
    format_host : Bool = false,
  ) : Nil
    prelude_sources = if prelude_code.strip.empty?
                        [] of PreludeSource
                      else
                        [PreludeSource.new("", "prelude.rb", prelude_code)]
                      end
    compile_graph(
      components,
      output_dir,
      prelude_sources,
      helpers,
      resources,
      format_host,
      [] of String,
      nil,
      legacy_prelude: !prelude_sources.empty?
    )
  end

  def compile_graph(
    components : Array(MochiComponent),
    output_dir : String,
    prelude_sources : Array(PreludeSource),
    helpers : Array(HelperUnit) = [] of HelperUnit,
    resources : Array(PackageResource) = [] of PackageResource,
    format_host : Bool = false,
    search_roots : Array(String) = [] of String,
    project_root : String? = nil,
    legacy_prelude : Bool = false,
  ) : Nil
    @chi_paths.clear
    @helper_chi_paths.clear
    @ruby_package_paths.clear
    @prelude_path = nil
    @format_host_path = nil
    @package_graph = nil
    @warnings.clear
    validate_component_inventory(components)
    Dir.mkdir_p(output_dir)
    components_dir = File.join(output_dir, COMPONENTS_DIR)
    Dir.mkdir_p(components_dir)
    # The output directory can be reused between builds. Descriptors from a
    # previous source tree must not look like part of this bundle.
    Dir.glob(File.join(components_dir, "*.json")).each { |path| File.delete(path) }

    @mrbc_path ||= resolved_mrbc_path

    @package_graph = MochiPackaging::PackageGraph.build(
      components,
      prelude_sources,
      helpers,
      search_roots,
      project_root
    )
    graph = @package_graph.not_nil!

    if legacy_prelude && !prelude_sources.empty?
      @prelude_path = compile_prelude(prelude_sources.first.source, components_dir)
    end

    graph.ruby_order.each do |package|
      path = compile_ruby_source(
        package.source,
        File.join(components_dir, package.file),
        package.id,
        package.source_path,
        package.line_offset
      )
      @ruby_package_paths << path
      @helper_chi_paths << path if package.helper
    end

    if format_host
      components.each { |component| component.manifest.formatting = true }
    end

    sorted_components = graph.component_order
    chi_paths_by_tag = {} of String => String
    errors = [] of String

    sorted_components.each do |component|
      begin
        chi_path = compile_component(component, components_dir)
        chi_paths_by_tag[component.manifest.tag_name] = chi_path
      rescue ex
        errors << "#{component.manifest.tag_name}: #{ex.message}"
      end
    end

    unless errors.empty?
      raise "mrbc failed:\n#{errors.join("\n")}"
    end

    @chi_paths = sorted_components.compact_map { |component| chi_paths_by_tag[component.manifest.tag_name]? }
    sorted_components.each do |component|
      write_component_descriptor(component.manifest, output_dir)
    end
    @wasm_path = copy_asset(resolved_wasm_source, output_dir, "mochi-gvm.wasm")
    @js_path = copy_asset(resolved_js_source, output_dir, "mochi-gvm.js")
    @loader_path = copy_asset(resolved_loader_source, output_dir, "mochi-loader.js")
    uses_format_host = format_host || graph.has_capability?("formatting")
    if uses_format_host
      @format_host_path = copy_asset(resolved_format_host_source, output_dir, "mochi-format.js")
      if @format_host_path.nil?
        @warnings << "mochi-format.js not found; set MOCHI_FORMAT_HOST or add runtime/mochi-format.js"
      end
    else
      stale_format_host = File.join(output_dir, "mochi-format.js")
      File.delete(stale_format_host) if File.exists?(stale_format_host)
    end

    if @wasm_path.nil?
      @warnings << "mochi-gvm.wasm not found; set MOCHI_GVM_WASM or place ../mochi-gvm/dist/mochi-gvm.wasm"
    end
    if @js_path.nil?
      @warnings << "mochi-gvm.js not found; set MOCHI_GVM_JS or place ../mochi-gvm/dist/mochi-gvm.js"
    end
    if @loader_path.nil?
      @warnings << "mochi-loader.js not found; set MOCHI_LOADER or add runtime/mochi-loader.js"
    end

    package_resources = collect_resources(components, resources)
    emit_resource_files(package_resources, output_dir)

    @manifest_path = File.join(output_dir, "mochi-manifest.json")
    File.write(@manifest_path.not_nil!, build_manifest_json(sorted_components, package_resources))
  end

  private def collect_resources(
    components : Array(MochiComponent),
    extra : Array(PackageResource),
  ) : Array(PackageResource)
    resources = {} of String => PackageResource
    (components.flat_map(&.manifest.style_resources) + extra).each do |resource|
      if previous = resources[resource.id]?
        if previous.kind != resource.kind || previous.text != resource.text ||
           previous.output_file != resource.output_file
          raise "conflicting package resource '#{resource.id}'"
        end
        next
      end
      resources[resource.id] = resource
    end
    # Shared style text is a separately loadable resource. The entry manifest
    # keeps only its identity and location; the loader fetches it when a
    # component that owns the resource first mounts.
    resources.values.sort_by(&.id).map do |resource|
      next resource unless resource.kind == "style" && resource.output_file.nil?

      PackageResource.new(
        resource.id,
        resource.kind,
        text: resource.text,
        output_file: File.join(COMPONENTS_DIR, "styles", "#{resource_digest(resource.id)}.css"),
        source_path: resource.source_path
      )
    end
  end

  private def resource_digest(id : String) : String
    Digest::SHA1.hexdigest(id)[0, 12]
  end

  private def emit_resource_files(resources : Array(PackageResource), output_dir : String) : Nil
    icon_root = File.join(output_dir, "mochi-icons")
    FileUtils.rm_rf(icon_root) if File.directory?(icon_root)
    style_root = File.join(output_dir, COMPONENTS_DIR, "styles")
    FileUtils.rm_rf(style_root) if File.directory?(style_root)
    resources.each do |resource|
      file = resource.output_file
      source = resource.source_path
      next unless file
      destination = File.join(output_dir, file)
      FileUtils.mkdir_p(File.dirname(destination))
      if source && File.file?(source)
        FileUtils.cp(source, destination)
      elsif text = resource.text
        File.write(destination, text)
      else
        raise "package resource '#{resource.id}' has no source file or text"
      end
    end
  end

  private def validate_component_inventory(components : Array(MochiComponent)) : Nil
    tags = {} of String => MochiComponent
    class_names = {} of String => MochiComponent

    components.each do |component|
      tag = component.manifest.tag_name
      if previous = tags[tag]?
        raise "duplicate component tag '#{tag}' at #{component_location(previous)} and #{component_location(component)}"
      end
      tags[tag] = component

      class_name = component.manifest.class_name
      if previous = class_names[class_name]?
        raise "duplicate component class '#{class_name}' at #{component_location(previous)} and #{component_location(component)}"
      end
      class_names[class_name] = component
    end
  end

  private def component_location(component : MochiComponent) : String
    return component.absolute_path if component.class_line <= 0

    "#{component.absolute_path}:#{component.class_line}"
  end

  private def compile_prelude(prelude_code : String, components_dir : String) : String
    chi_path = File.join(components_dir, "prelude.chi")
    compile_ruby_source(prelude_code, chi_path, "prelude")
  end

  private def compile_component(component : MochiComponent, components_dir : String) : String
    manifest = component.manifest
    chi_path = File.join(components_dir, manifest.chi_file)
    compile_ruby_source(
      component.ruby_code,
      chi_path,
      manifest.tag_name,
      manifest.source_file,
      component.source_line_offset
    )
  end

  private def compile_ruby_source(
    ruby_code : String,
    chi_path : String,
    label : String,
    source_path : String? = nil,
    source_line_offset : Int32 = 1,
  ) : String
    source = SorbetTypeStripper.strip(ruby_code)
    source = GvmSourcePreparer.strip_class_ivars(source)

    prefix = "mochi-#{safe_name(label)}"
    ruby_file = File.tempfile(prefix, ".rb")
    mrb_file = File.tempfile(prefix, ".mrb")

    begin
      ruby_file.print(source)
      ruby_file.close
      mrb_file.close

      run_mrbc(ruby_file.path, mrb_file.path, source_path, source_line_offset)

      bytecode = File.read(mrb_file.path).to_slice
      verify_context = source_path ? "#{label} (#{source_path})" : label
      RiteVerifier.verify!(bytecode, verify_context)
      body = strip_rite_header(bytecode, label)

      File.write(chi_path, body)
      chi_path
    ensure
      File.delete(ruby_file.path) if File.exists?(ruby_file.path)
      File.delete(mrb_file.path) if File.exists?(mrb_file.path)
    end
  end

  private def run_mrbc(
    ruby_path : String,
    output_path : String,
    source_path : String? = nil,
    source_line_offset : Int32 = 1,
  ) : Nil
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
    if source_path
      # mrbc names the temporary file it read and counts from the start of
      # the component slice. Translate both before the tempfile disappears.
      message = message.gsub(ruby_path, source_path)
      message = message.gsub(/#{Regex.escape(source_path)}:(\d+)/) do
        "#{source_path}:#{$1.to_i + source_line_offset - 1}"
      end
    end
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

  private def resolved_format_host_source : String?
    @format_host_source || self.class.find_format_host
  end

  private def self.search_roots : Array(String)
    roots = [Dir.current]
    if exe = Process.executable_path
      exe_dir = File.dirname(exe)
      roots << exe_dir
      roots << File.expand_path("..", exe_dir)
    end
    roots.uniq
  end

  @@cached_mrbc : String?
  @@mrbc_resolved : Bool = false
  @@cached_wasm : String?
  @@wasm_resolved : Bool = false
  @@cached_js : String?
  @@js_resolved : Bool = false
  @@cached_loader : String?
  @@loader_resolved : Bool = false
  @@cached_format_host : String?
  @@format_host_resolved : Bool = false

  def self.find_mrbc : String?
    return @@cached_mrbc if @@mrbc_resolved
    @@mrbc_resolved = true

    if found = Process.find_executable("mrbc")
      return @@cached_mrbc = found
    end
    candidates = [] of String
    search_roots.each do |root|
      candidates << File.join(root, "build_wasm", "mruby", "src", "build", "host", "bin", "mrbc")
      candidates << File.join(root, "build_wasm", "mruby", "src", "build", "mochi-v2-host", "bin", "mrbc")
      candidates << File.join(root, "..", "build_wasm", "mruby", "src", "build", "host", "bin", "mrbc")
      candidates << File.join(root, "..", "build_wasm", "mruby", "src", "build", "mochi-v2-host", "bin", "mrbc")
    end
    @@cached_mrbc = first_existing_executable(candidates)
  end

  def self.find_wasm : String?
    return @@cached_wasm if @@wasm_resolved
    @@wasm_resolved = true

    candidates = [] of String
    search_roots.each do |root|
      candidates << File.join(root, "..", "mochi-gvm", "dist", "mochi-gvm.wasm")
      candidates << File.join(root, "..", "..", "mochi-gvm", "dist", "mochi-gvm.wasm")
      candidates << File.join(root, "mochi-gvm", "dist", "mochi-gvm.wasm")
      candidates << File.join(root, "dist", "mochi-gvm.wasm")
    end

    @@cached_wasm = first_existing_file(candidates)
  end

  def self.find_js : String?
    return @@cached_js if @@js_resolved
    @@js_resolved = true

    candidates = [] of String
    search_roots.each do |root|
      candidates << File.join(root, "..", "mochi-gvm", "dist", "mochi-gvm.js")
      candidates << File.join(root, "..", "..", "mochi-gvm", "dist", "mochi-gvm.js")
      candidates << File.join(root, "mochi-gvm", "dist", "mochi-gvm.js")
      candidates << File.join(root, "dist", "mochi-gvm.js")
    end

    @@cached_js = first_existing_file(candidates)
  end

  def self.find_loader : String?
    return @@cached_loader if @@loader_resolved
    @@loader_resolved = true

    candidates = [] of String
    search_roots.each do |root|
      candidates << File.join(root, "runtime", "mochi-loader.js")
      candidates << File.join(root, "..", "runtime", "mochi-loader.js")
      candidates << File.join(root, "..", "..", "runtime", "mochi-loader.js")
      candidates << File.join(root, "..", "mochi-gvm", "runtime", "mochi-loader.js")
      candidates << File.join(root, "..", "..", "mochi-gvm", "runtime", "mochi-loader.js")
    end

    @@cached_loader = first_existing_file(candidates)
  end

  def self.find_format_host : String?
    return @@cached_format_host if @@format_host_resolved
    @@format_host_resolved = true

    candidates = [] of String
    search_roots.each do |root|
      candidates << File.join(root, "runtime", "mochi-format.js")
      candidates << File.join(root, "..", "runtime", "mochi-format.js")
      candidates << File.join(root, "..", "..", "runtime", "mochi-format.js")
      candidates << File.join(root, "..", "mochi-gvm", "runtime", "mochi-format.js")
      candidates << File.join(root, "..", "..", "mochi-gvm", "runtime", "mochi-format.js")
    end

    @@cached_format_host = first_existing_file(candidates)
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

  private def build_manifest_json(
    components : Array(MochiComponent),
    resources : Array(PackageResource),
  ) : String
    graph = @package_graph
    JSON.build do |json|
      json.object do
        json.field "schema_version", MochiPackaging::SCHEMA_VERSION
        if prelude = @prelude_path
          json.field "prelude", File.basename(prelude)
        end
        if format_host = @format_host_path
          json.field "format_host", File.basename(format_host)
        end
        if graph
          unless graph.capabilities.empty?
            json.field "capabilities" do
              json.object do
                graph.capabilities.keys.sort.each do |name|
                  capability = graph.capabilities[name]
                  json.field name do
                    json.object do
                      json.field "version", capability.version
                      if host = capability.host
                        json.field "host", host
                      end
                      json.field "packages" do
                        json.array do
                          capability.packages.sort.each { |id| json.string(id) }
                        end
                      end
                    end
                  end
                end
              end
            end
          end
          json.field "entry_packages" do
            json.array do
              graph.entry_packages.each { |id| json.string(id) }
            end
          end
          json.field "packages" do
            json.object do
              graph.order.each do |id|
                package = graph.packages[id]
                write_package(json, package)
              end
            end
          end
        end
        unless resources.empty?
          json.field "resources" do
            json.object do
              resources.each { |resource| write_resource(json, resource) }
            end
          end
        end
        json.field "components" do
          json.array do
            components.each do |component|
              write_component_index(json, component.manifest)
            end
          end
        end
        json.field "wasm_file", @wasm_path ? File.basename(@wasm_path.not_nil!) : nil
        json.field "js_file", @js_path ? File.basename(@js_path.not_nil!) : nil
        json.field "loader_file", @loader_path ? File.basename(@loader_path.not_nil!) : nil
      end
    end
  end

  private def component_descriptor_file(tag_name : String) : String
    File.join(COMPONENTS_DIR, "#{tag_name}.json")
  end

  # The entry manifest carries only the identities needed to register custom
  # elements and the location of each component's descriptor. Templates,
  # styles, bindings, props, and dependency ids stay in the descriptor and are
  # fetched when the component is first used.
  private def write_component_index(json : JSON::Builder, manifest : ComponentManifest) : Nil
    json.object do
      json.field "tag_name", manifest.tag_name
      json.field "class_name", manifest.class_name
      json.field "descriptor", component_descriptor_file(manifest.tag_name)
      if package_id = manifest.package_id
        json.field "package", package_id
      end
    end
  end

  private def write_component_descriptor(manifest : ComponentManifest, output_dir : String) : Nil
    path = File.join(output_dir, component_descriptor_file(manifest.tag_name))
    File.write(path, build_component_descriptor_json(manifest))
  end

  private def build_component_descriptor_json(manifest : ComponentManifest) : String
    JSON.build do |json|
      json.object do
        json.field "schema_version", MochiPackaging::SCHEMA_VERSION
        write_component_fields(json, manifest)
      end
    end
  end

  private def write_package(json : JSON::Builder, package : MochiPackaging::PackageNode) : Nil
    json.field package.id do
      json.object do
        json.field "kind", package.kind
        json.field "file", File.join(COMPONENTS_DIR, package.file)
        if component = package.component
          json.field "tag_name", component.manifest.tag_name
          json.field "class_name", component.manifest.class_name
        end
        json.field "source" do
          json.object do
            json.field "file", package.source_path
            json.field "line", package.source_line
          end
        end
        unless package.dependencies.empty?
          json.field "dependencies" do
            json.array do
              package.dependencies.sort.each { |dependency| json.string(dependency) }
            end
          end
        end
        unless package.resources.empty?
          json.field "resources" do
            json.array do
              package.resources.sort.each { |resource| json.string(resource) }
            end
          end
        end
        unless package.capabilities.empty?
          json.field "capabilities" do
            json.array do
              package.capabilities.sort.each { |capability| json.string(capability) }
            end
          end
        end
        unless package.exports.empty?
          json.field "exports" do
            json.array do
              package.exports.sort.each { |name| json.string(name) }
            end
          end
        end
      end
    end
  end

  private def write_resource(json : JSON::Builder, resource : PackageResource) : Nil
    json.field resource.id do
      json.object do
        json.field "kind", resource.kind
        # A resource with a file is fetched on demand and never inlined.
        if file = resource.output_file
          json.field "file", file
        elsif text = resource.text
          json.field "text", text
        end
      end
    end
  end

  private def write_component_fields(json : JSON::Builder, manifest : ComponentManifest) : Nil
    json.field "tag_name", manifest.tag_name
    json.field "class_name", manifest.class_name
    json.field "chi_file", manifest.chi_file
    if package_id = manifest.package_id
      json.field "package", package_id
    end
    if helper_chi = manifest.helper_chi
      json.field "helper_chi", helper_chi
    end
    unless manifest.dependencies.empty?
      json.field "dependencies" do
        json.array do
          manifest.dependencies.sort.each { |dependency| json.string(dependency) }
        end
      end
    end
    unless manifest.capabilities.empty?
      json.field "capabilities" do
        json.array do
          manifest.capabilities.sort.each { |capability| json.string(capability) }
        end
      end
    end
    if manifest.formatting
      json.field "formatting", true
    end
    json.field "html_template", manifest.html_template
    unless manifest.style_resources.empty?
      json.field "style_resources" do
        json.array do
          manifest.style_resource_ids.each { |id| json.string(id) }
        end
      end
    end
    json.field "css", manifest.css
    if source_file = manifest.source_file
      json.field "source" do
        json.object do
          json.field "file", source_file
          json.field "line", manifest.source_line
        end
      end
      unless manifest.method_lines.empty?
        json.field "methods" do
          json.object do
            manifest.method_lines.to_a.sort_by(&.[0]).each do |name, line|
              json.field name, line
            end
          end
        end
      end
    end

    unless manifest.props.empty?
      json.field "props" do
        json.array do
          manifest.props.each { |prop| write_prop(json, prop, manifest.source_file) }
        end
      end
    end

    unless manifest.emits.empty?
      json.field "emits" do
        json.array do
          manifest.emits.each { |event| write_emit(json, event, manifest.source_file) }
        end
      end
    end

    write_bindings(json, manifest.bindings)
    write_events(json, manifest.events)
  end

  private def write_prop(json : JSON::Builder, prop : PropDescriptor, fallback_file : String?) : Nil
    json.object do
      json.field "name", prop.name
      json.field "type", prop.type
      json.field "required", true if prop.required
      json.field "default", true if prop.default
      if file = prop.source_file || fallback_file
        json.field "source" do
          json.object do
            json.field "file", file
            json.field "line", prop.source_line
          end
        end
      end
    end
  end

  private def write_emit(json : JSON::Builder, event : ComponentEventDescriptor, fallback_file : String?) : Nil
    json.object do
      json.field "name", event.name
      json.field "payload" do
        json.array do
          event.payload.each do |field|
            json.object do
              json.field "name", field.name
              json.field "type", field.type
            end
          end
        end
      end
      if file = event.source_file || fallback_file
        json.field "source" do
          json.object do
            json.field "file", file
            json.field "line", event.source_line
          end
        end
      end
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
      json.field "trusted_markup", true if binding.trusted_markup
      json.field "attr_name", binding.attr_name
      json.field "attr_kind", binding.attr_kind if binding.attr_kind
      json.field "template_text", binding.template_text
      json.field "getter_sym", binding.getter_sym
      json.field "setter_sym", binding.setter_sym
      if binding.kind == "expr"
        json.field "getter_expr", binding.getter_expr
      end
      if start = binding.template_start
        json.field "template_start", start
      end
      if finish = binding.template_end
        json.field "template_end", finish
      end
      unless binding.scope.empty?
        json.field "scope" do
          json.array do
            binding.scope.each { |name| json.string(name) }
          end
        end
      end
      if span = binding.span
        write_span(json, span)
      end
      if rows = binding.each_rows
        write_each_rows(json, rows)
      end

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

  private def write_each_rows(json : JSON::Builder, rows : EachRowTemplate) : Nil
    json.field "each_rows" do
      write_each_rows_object(json, rows)
    end
  end

  private def write_each_rows_object(json : JSON::Builder, rows : EachRowTemplate) : Nil
    json.object do
      json.field "id", rows.block_id
      json.field "keyed", true if rows.key_expression
      if span = rows.span
        write_span(json, span)
      end
      json.field "template", rows.template
      json.field "bindings" do
        json.array do
          rows.bindings.each do |binding|
            json.object do
              json.field "slot", binding.slot
              json.field "kind", binding.kind
              json.field "trusted_markup", true if binding.trusted_markup
              json.field "attr_name", binding.attr_name
              json.field "attr_kind", binding.attr_kind if binding.attr_kind
              if span = binding.span
                write_span(json, span)
              end
            end
          end
        end
      end
      json.field "children" do
        json.array do
          rows.children.each { |child| write_each_rows_object(json, child) }
        end
      end
    end
  end

  private def write_span(json : JSON::Builder, span : TemplateSourceSpan) : Nil
    json.field "source" do
      json.object do
        json.field "file", span.file
        json.field "line", span.line
        json.field "column", span.column
        json.field "end_line", span.end_line
        json.field "end_column", span.end_column
        json.field "length", span.length
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
            json.field "component", true if event.component
            unless event.modifiers.empty?
              json.field "modifiers" do
                json.array do
                  event.modifiers.each { |modifier| json.string(modifier) }
                end
              end
            end
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
