require "../clay/portable_fonts"
require "json"
require "file_utils"
require "digest/sha1"
require "../mochi_cmp"
require "../clay/profile"
require "../clay/desktop_scene"
require "../tooling/installation_paths"
require "../sorbet/type_stripper"
require "../webcomponents/resource_manifest"
require "../webcomponents/component_prop_attributes"
require "./package_graph"
require "./source_preparer"
require "./rite_verifier"
require "./rite_debug_info"
require "./capacity_config"
require "./capacity_artifact_builder"

class MrbcCompiler
  RITE_HEADER     = "RITE0400\u0000\u0000"
  COMPONENTS_DIR  = "components"
  COMPILE_WORKERS = 4

  @capacity_artifacts : CapacityArtifactBuilder::Artifacts?

  getter manifest_path : String?
  getter chi_paths : Array(String)
  getter helper_chi_paths : Array(String)
  getter ruby_package_paths : Array(String)
  getter prelude_path : String?
  getter wasm_path : String?
  getter js_path : String?
  getter loader_path : String?
  getter format_host_path : String?
  getter host_adapter_paths : Hash(String, String)
  getter package_graph : MochiPackaging::PackageGraph?
  getter warnings : Array(String)
  getter capacity_config : CapacityConfig

  def initialize(
    @mrbc_path : String? = ENV["MRBC"]?,
    @wasm_source : String? = ENV["MOCHI_GVM_WASM"]?,
    @loader_source : String? = ENV["MOCHI_LOADER"]?,
    @js_source : String? = ENV["MOCHI_GVM_JS"]?,
    @format_host_source : String? = ENV["MOCHI_FORMAT_HOST"]?,
    @host_adapter_sources : Hash(String, String)? = nil,
    capacity_config_path : String? = nil,
    @render_target : RenderTarget = RenderTarget::Dom,
  )
    @capacity_config = capacity_config_path ? CapacityConfig.read(capacity_config_path) : CapacityConfig.default
    @capacity_artifacts = nil
    @manifest_path = nil
    @chi_paths = [] of String
    @helper_chi_paths = [] of String
    @ruby_package_paths = [] of String
    @prelude_path = nil
    @wasm_path = nil
    @js_path = nil
    @loader_path = nil
    @format_host_path = nil
    @host_adapter_paths = {} of String => String
    @package_graph = nil
    @warnings = [] of String
  end

  def validate_emitted_resources! : Nil
    return if @warnings.empty?
    details = @warnings.map { |warning| "- #{warning}" }.join("\n")
    raise "Mochi setup: build resources are incomplete:\n#{details}"
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
    portable_project : PortableProject? = nil,
    staged_project_dir : String? = nil,
    before_emit : Proc(Nil)? = nil,
  ) : Nil
    @chi_paths.clear
    @helper_chi_paths.clear
    @ruby_package_paths.clear
    @prelude_path = nil
    @format_host_path = nil
    @host_adapter_paths.clear
    @package_graph = nil
    @warnings.clear
    validate_component_inventory(components)
    @package_graph = MochiPackaging::PackageGraph.build(
      components,
      prelude_sources,
      helpers,
      search_roots,
      project_root,
      portable_project.try(&.root)
    )
    graph = @package_graph.not_nil!
    desktop_scene = if portable_project
                      validate_portable_project(graph, portable_project, staged_project_dir.not_nil!, project_root.not_nil!)
                    end
    if @render_target.desktop? && !desktop_scene
      raise "The desktop target requires #{PortableProject::FILE_NAME}"
    end

    @mrbc_path ||= resolved_mrbc_path
    before_emit.try(&.call)
    manifest_path = File.join(output_dir, "mochi-manifest.json")
    File.delete(manifest_path) if File.exists?(manifest_path)
    components_dir = File.join(output_dir, COMPONENTS_DIR)
    Dir.mkdir_p(components_dir)
    # Descriptors from a previous source tree must not enter this bundle.
    Dir.glob(File.join(components_dir, "*.json")).each { |path| File.delete(path) }

    if legacy_prelude && !prelude_sources.empty?
      @prelude_path = compile_prelude(prelude_sources.first.source, components_dir)
    end

    if format_host
      graph.ensure_capability("formatting")
      components.each do |component|
        component.manifest.formatting = true
        unless component.manifest.capabilities.includes?("formatting")
          component.manifest.capabilities << "formatting"
        end
      end
    end

    sorted_components = graph.component_order
    ComponentPropAttributes.apply(sorted_components.map(&.manifest))
    jobs = [] of Tuple(String, String, String, String?, Int32)
    graph.ruby_order.each do |package|
      jobs << {
        package.source,
        File.join(components_dir, package.file),
        package.id,
        package.source_path,
        package.line_offset,
      }
    end
    sorted_components.each do |component|
      manifest = component.manifest
      jobs << {
        component.ruby_code,
        File.join(components_dir, manifest.chi_file),
        manifest.tag_name,
        manifest.source_file,
        component.source_line_offset,
      }
    end

    compiled_paths = begin
      compile_independent_sources(jobs)
    rescue ex
      if prelude = @prelude_path
        File.delete(prelude) if File.exists?(prelude)
      end
      raise ex
    end
    package_count = graph.ruby_order.size
    @ruby_package_paths.concat(compiled_paths[0, package_count])
    graph.ruby_order.each_with_index do |package, index|
      @helper_chi_paths << compiled_paths[index] if package.helper
    end
    @chi_paths = compiled_paths[package_count, sorted_components.size]
    if @render_target.desktop?
      path = File.join(output_dir, "scene.json")
      File.write(path, desktop_scene.not_nil!)
      @manifest_path = path
      return
    end
    sorted_components.each do |component|
      write_component_descriptor(component.manifest, output_dir)
    end
    if @capacity_config.fingerprint != CapacityConfig.default.fingerprint
      gvm_root = InstallationPaths.new.gvm_root || raise("Mochi setup: GVM source not found for custom capacity build")
      @capacity_artifacts = CapacityArtifactBuilder.new(gvm_root, @capacity_config).build
    end
    wasm_source = selected_wasm_source
    validate_capacity_artifact!(wasm_source) if wasm_source && File.file?(wasm_source)
    @wasm_path = copy_asset(wasm_source, output_dir, "mochi-gvm.wasm")
    @js_path = copy_asset(selected_js_source, output_dir, "mochi-gvm.js")
    @loader_path = copy_asset(resolved_loader_source, output_dir, "mochi-loader.js")
    used_hosts = graph.capabilities.values.compact_map(&.host)
    used_hosts << "mochi-format.js" if format_host
    used_hosts.uniq.sort.each do |host|
      path = copy_asset(resolved_host_adapter_source(host), output_dir, host)
      if path
        @host_adapter_paths[host] = path
      else
        @warnings << "#{host} not found; add it under runtime/ or set its source explicitly"
      end
    end
    @format_host_path = @host_adapter_paths["mochi-format.js"]?
    MochiPackaging::CAPABILITY_DEFINITIONS.each do |definition|
      host = definition.host
      next if host.nil? || used_hosts.includes?(host)
      stale = File.join(output_dir, host)
      File.delete(stale) if File.exists?(stale)
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

    package_resources = collect_resources(sorted_components, resources)
    emit_resource_files(package_resources, output_dir)

    @manifest_path = manifest_path
    File.write(@manifest_path.not_nil!, build_manifest_json(sorted_components, package_resources))
  end

  private def validate_portable_project(
    graph : MochiPackaging::PackageGraph,
    project : PortableProject,
    staged_root : String,
    project_dir : String,
  ) : String
    components = graph.component_order.to_h { |component| {component.manifest.tag_name, component.manifest} }
    receivers = MochiPackaging::CAPABILITY_DEFINITIONS.select(&.host).map(&.exporting).reject { |name| name.empty? || name.includes?('.') }.to_set
    graph.component_order.each do |component|
      manifest = component.manifest
      profile = component.portable_profile.not_nil!
      profile.validate_template(components, receivers)
      if profile.editing && @render_target.dom?
        graph.ensure_capability("editing")
        graph.capabilities["editing"].packages << manifest.package_id.not_nil!
        manifest.capabilities << "editing"
      end
      composition = profile.compose_styles(component.absolute_path, staged_root)
      manifest.css = component.css = composition.css
      manifest.style_resources = composition.resources

      package = graph.packages[manifest.package_id]
      package.resources = manifest.style_resource_ids
      dependencies = graph.reachable_from(package.id)
      # Diagnose calls in a package before calls inside its dependencies.
      graph.order.reverse_each do |id|
        next unless dependencies.includes?(id)
        node = graph.packages[id]
        next if node.component? && node.id != package.id
        ClayProfile.validate_ruby(node.source, node.source_path, node.line_offset, component.name, receivers)
      end
    end

    font_plans = {} of String => PortableFonts
    graph.component_order.each do |component|
      profile = component.portable_profile.not_nil!
      manifest = component.manifest
      PortableTemplate::SourceMap.new(profile.source_marks, manifest.class_name,
        manifest.source_file, manifest.source_line).apply(manifest.portable_nodes.not_nil!)
      fonts = PortableFonts.new(project, project_dir, profile)
      window = manifest.tag_name == project.root ? project.window : nil
      document_css = window ? "body:has(> #{project.root}){margin:0;background:#ffffff}\n" : ""
      fonts.resolve(manifest.portable_nodes.not_nil!)
      document_style = fonts.document_stylesheet(document_css)
      manifest.css = component.css = fonts.browser_css(manifest.css, window.try(&.host_css) || "")
      manifest.css = component.css = PortableStyles::EDITOR_CSS + manifest.css if profile.editing
      manifest.font_resources = fonts.resources
      if resource = document_style
        manifest.document_style = resource.id
        manifest.font_resources << resource
      end
      graph.packages[manifest.package_id].resources.concat(manifest.font_resources.map(&.id))
      font_plans[manifest.tag_name] = fonts
    end
    packages = graph.order.map { |id| graph.packages[id].file }
    DesktopScene.write(project, graph.component_order, packages, @capacity_config.fingerprint, font_plans)
  end

  private def collect_resources(
    components : Array(MochiComponent),
    extra : Array(PackageResource),
  ) : Array(PackageResource)
    resources = {} of String => PackageResource
    (components.flat_map { |component| component.manifest.style_resources + component.manifest.font_resources } + extra).each do |resource|
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

  # Package and component bytecode is independently loadable. Compile these
  # jobs with a small fixed worker pool, then restore graph order before
  # publishing paths and diagnostics so the output remains deterministic.
  private def compile_independent_sources(
    jobs : Array(Tuple(String, String, String, String?, Int32)),
  ) : Array(String)
    return [] of String if jobs.empty?

    worker_count = {COMPILE_WORKERS, jobs.size}.min
    job_channel = Channel(Int32).new(jobs.size)
    result_channel = Channel(Tuple(Int32, String?, String?)).new(jobs.size)
    worker_count.times do
      spawn do
        while index = job_channel.receive?
          source, output, label, source_path, line_offset = jobs[index]
          begin
            path = compile_ruby_source(source, output, label, source_path, line_offset)
            result_channel.send({index, path, nil})
          rescue ex
            result_channel.send({index, nil, ex.message || ex.class.name})
          end
        end
      end
    end

    jobs.each_index { |index| job_channel.send(index) }
    job_channel.close

    results = Array(Tuple(String?, String?)).new(jobs.size) { {nil, nil} }
    jobs.size.times do
      index, path, error = result_channel.receive
      results[index] = {path, error}
    end

    errors = [] of String
    paths = [] of String
    results.each_with_index do |(path, error), index|
      if message = error
        errors << "#{jobs[index][2]}: #{message}"
      elsif compiled_path = path
        paths << compiled_path
      else
        errors << "#{jobs[index][2]}: compilation worker returned no result"
      end
    end
    unless errors.empty?
      jobs.each do |job|
        output = job[1]
        File.delete(output) if File.exists?(output)
      end
      raise "mrbc failed:\n#{errors.join("\n")}"
    end
    paths
  end

  private def compile_ruby_source(
    ruby_code : String,
    chi_path : String,
    label : String,
    source_path : String? = nil,
    source_line_offset : Int32 = 1,
  ) : String
    source = SorbetTypeStripper.strip(ruby_code)
    source = GvmSourcePreparer.strip_class_ivars(source, source_path || label, source_line_offset)
    GvmSourcePreparer.validate_control_flow!(source, source_path || label, source_line_offset)

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
      begin
        RiteVerifier.verify!(bytecode, verify_context)
      rescue error : RiteVerifier::Unsupported
        run_mrbc(ruby_file.path, mrb_file.path, source_path, source_line_offset, debug: true)
        debug_line = RiteDebugInfo.line_for(File.read(mrb_file.path).to_slice, error.irep_index, error.pc)
        if line = debug_line
          authored_line = line + source_line_offset - 1
          if source_path && File.exists?(source_path) && authored_line > File.read_lines(source_path).size
            raise "#{source_path}: unsupported #{error.construct}; no exact authored source span available " \
                  "(generated code, IREP ##{error.irep_index} at pc=#{error.pc})"
          end
          raise "#{source_path || label}:#{authored_line}: unsupported #{error.construct} " \
                "(IREP ##{error.irep_index} at pc=#{error.pc})"
        end
        raise "#{source_path || label}: unsupported #{error.construct}; no exact authored source span available " \
              "(IREP ##{error.irep_index} at pc=#{error.pc})"
      end
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
    debug : Bool = false,
  ) : Nil
    mrbc = resolved_mrbc_path
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(
      mrbc,
      debug ? ["-g", "-o", output_path, ruby_path] : ["-o", output_path, ruby_path],
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
    @mrbc_path || InstallationPaths.new.mrbc || raise "Mochi setup: mrbc not found; set MRBC or run `task install`"
  end

  private def resolved_wasm_source : String?
    @wasm_source || InstallationPaths.new.wasm
  end

  private def selected_wasm_source : String?
    @capacity_artifacts.try(&.wasm) || resolved_wasm_source
  end

  private def selected_js_source : String?
    @capacity_artifacts.try(&.js) || resolved_js_source
  end

  private def validate_capacity_artifact!(wasm_source : String) : Nil
    profile_path = wasm_source.sub(/\.wasm\z/, ".capacity.json")
    unless File.file?(profile_path)
      raise "Mochi setup: capacity profile metadata is missing beside #{wasm_source}; rebuild GVM"
    end
    actual = JSON.parse(File.read(profile_path))
    expected = JSON.parse(@capacity_config.profile_json)
    actual_fingerprint = actual.as_h?.try(&.["fingerprint"]?).try(&.as_s?) || "invalid"
    unless actual == expected
      raise "Mochi setup: GVM capacity profile mismatch (expected #{@capacity_config.fingerprint}, actual #{actual_fingerprint}); select or rebuild the matching runtime"
    end
  rescue ex : JSON::ParseException
    raise "Mochi setup: invalid GVM capacity profile metadata at #{profile_path}: #{ex.message}"
  rescue ex : TypeCastError
    raise "Mochi setup: invalid GVM capacity profile metadata at #{profile_path}: expected an object"
  end

  private def resolved_js_source : String?
    return @js_source if @js_source

    if wasm_source = @wasm_source
      sibling = wasm_source.sub(/\.wasm\z/, ".js")
      return sibling if File.file?(sibling)
    end

    InstallationPaths.new.js
  end

  private def resolved_loader_source : String?
    @loader_source || InstallationPaths.new.loader
  end

  private def resolved_host_adapter_source(host : String) : String?
    if sources = @host_adapter_sources
      if source = sources[host]?
        return source
      end
    end
    if host == "mochi-format.js" && (source = @format_host_source)
      return source
    end
    InstallationPaths.new.host_adapter(host)
  end

  def self.find_format_host : String?
    InstallationPaths.new.format_host
  end

  def self.find_host_adapter(host : String) : String?
    InstallationPaths.new.host_adapter(host)
  end

  def self.find_mrbc : String?
    InstallationPaths.new.mrbc
  end

  def self.find_wasm : String?
    InstallationPaths.new.wasm
  end

  def self.find_js : String?
    InstallationPaths.new.js
  end

  def self.find_loader : String?
    InstallationPaths.new.loader
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
        json.field "capacity_profile" do
          json.raw(@capacity_config.profile_json)
        end
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
                      json.field "operations" do
                        json.object do
                          capability.operations.sort_by(&.name).each do |operation|
                            json.field operation.name, operation.mode
                          end
                        end
                      end
                      json.field "packages" do
                        json.array do
                          capability.packages.sort.each { |id| json.string(id) }
                        end
                      end
                      if capability.host
                        json.field "limits" do
                          json.object do
                            capability.limit_keys.sort_by(&.first).each do |name, capacity_key|
                              json.field name, @capacity_config[capacity_key]
                            end
                          end
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
    json.field "document_style", manifest.document_style if manifest.document_style
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

    manifest.write_contracts(json)
    write_bindings(json, manifest.bindings)
    write_events(json, manifest.events)
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
                json.field "context_tag", branch.context_tag
                json.field "context_namespace", branch.context_namespace
                write_span(json, span) if span = branch.span
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

  private def write_each_rows_object(json : JSON::Builder, rows : EachRowFragment) : Nil
    json.object do
      json.field "id", rows.block_id
      json.field "keyed", true if rows.is_a?(EachRowTemplate) && rows.key_expression
      json.field "context_tag", rows.context_tag
      json.field "context_namespace", rows.context_namespace
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
      unless rows.conditionals.empty?
        json.field "conditionals" do
          json.array do
            rows.conditionals.each do |conditional|
              json.object do
                json.field "id", conditional.id
                write_span(json, span) if span = conditional.span
                json.field "branches" do
                  json.array { conditional.branches.each { |branch| write_each_rows_object(json, branch) } }
                end
              end
            end
          end
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
