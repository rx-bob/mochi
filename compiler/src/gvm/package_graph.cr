require "digest/sha1"
require "../mochi_cmp"
require "../tree-sitter/imports_extractor"
require "../tree-sitter/source_symbols"

# Build-time dependency graph for generated GVM bundles.
#
# Package identities are logical and build-local absolute paths never enter the
# manifest. Components own one package each. Ruby files without components and
# the non-component code in a component file each own one package. Dependencies
# come from literal require/require_relative calls, constant ownership, and
# static component tag references in templates.
module MochiPackaging
  # Bundle schema shared by the entry manifest and the per-component
  # descriptors it points at. Both halves move together.
  SCHEMA_VERSION   = 3
  RUNTIME_REQUIRES = Set{"await"}

  # A host capability operation is either a synchronous WASM-to-JS call or an
  # asynchronous request whose result is delivered back to a live component.
  record CapabilityOperation,
    name : String,
    mode : String

  # Build-time registry for optional capabilities backed by a local browser
  # adapter. A definition only enters the manifest when a reachable package
  # exports its Ruby API; the compiler never bundles an adapter just because it
  # exists in the repository.
  record CapabilityDefinition,
    name : String,
    version : Int32,
    host : String?,
    exporting : String,
    operations : Array(CapabilityOperation),
    limit_keys : Array(Tuple(String, String))

  CAPABILITY_DEFINITIONS = [
    CapabilityDefinition.new(
      "download", 1, "mochi-download.js", "MochiDownload",
      [CapabilityOperation.new("save", "sync")],
      [{"bytes", "host_file_buffer_bytes"}, {"retained_bytes", "host_event_queue_bytes"}, {"leases", "host_file_handles"}]
    ),
    CapabilityDefinition.new(
      "time", 1, "mochi-time.js", "Time",
      [CapabilityOperation.new("now", "sync")],
      [] of Tuple(String, String)
    ),
    CapabilityDefinition.new(
      "formatting",
      1,
      "mochi-format.js",
      "MochiFormat",
      [CapabilityOperation.new("format", "sync")],
      [{"cache_entries", "host_format_cache_entries"}]
    ),
    CapabilityDefinition.new(
      "network",
      1,
      "mochi-fetch.js",
      "Mochi.fetch",
      [CapabilityOperation.new("fetch", "async"), CapabilityOperation.new("cancel", "sync")],
      [
        {"pending_requests", "host_network_pending_requests"},
        {"response_bytes", "host_network_response_bytes"},
        {"response_buffer_bytes", "host_network_buffer_bytes"},
        {"envelope_bytes", "host_fetch_envelope_bytes"},
      ]
    ),
    CapabilityDefinition.new(
      "layout",
      1,
      "mochi-layout.js",
      "MochiLayout",
      [CapabilityOperation.new("measure", "async"), CapabilityOperation.new("observe", "async"), CapabilityOperation.new("cancel", "async")],
      [{"requests", "bindings"}]
    ),
    CapabilityDefinition.new(
      "shortcuts",
      1,
      "mochi-shortcuts.js",
      "MochiShortcuts",
      [CapabilityOperation.new("register", "async"), CapabilityOperation.new("cancel", "async")],
      [{"registrations", "bindings"}]
    ),
    CapabilityDefinition.new(
      "pointer",
      1,
      "mochi-pointer.js",
      "MochiPointer",
      [CapabilityOperation.new("capture", "sync"), CapabilityOperation.new("release", "sync")],
      [] of Tuple(String, String)
    ),
    CapabilityDefinition.new(
      "drag",
      1,
      "mochi-drag.js",
      "MochiDrag",
      [CapabilityOperation.new("set_data", "sync"), CapabilityOperation.new("set_text", "sync"), CapabilityOperation.new("accept", "sync")],
      [{"payload_bytes", "host_drag_payload_bytes"}]
    ),
    CapabilityDefinition.new(
      "files",
      1,
      "mochi-files.js",
      "MochiFiles",
      [CapabilityOperation.new("release", "sync"), CapabilityOperation.new("open", "sync"), CapabilityOperation.new("close", "sync"), CapabilityOperation.new("read_next", "async"), CapabilityOperation.new("read", "async"), CapabilityOperation.new("read_text", "async")],
      [
        {"handles", "host_file_handles"},
        {"metadata_bytes", "host_event_args_bytes"},
        {"readers", "host_file_readers"},
        {"chunk_bytes", "host_file_chunk_bytes"},
        {"whole_read_bytes", "host_file_whole_read_bytes"},
        {"envelope_bytes", "host_fetch_envelope_bytes"},
      ]
    ),
  ]

  record Capability,
    name : String,
    version : Int32,
    host : String?,
    operations : Array(CapabilityOperation),
    packages : Array(String),
    limit_keys : Array(Tuple(String, String))

  class PackageNode
    getter id : String
    getter kind : String
    getter file : String
    getter absolute_path : String
    getter source_path : String
    getter source_line : Int32
    getter source : String
    getter line_offset : Int32
    getter exports : Array(String)
    getter references : Array(String)
    getter method_calls : Array(String)
    getter component : MochiComponent?
    getter helper : HelperUnit?
    property dependencies : Array(String)
    property resources : Array(String)
    property capabilities : Array(String)

    def initialize(
      @id : String,
      @kind : String,
      @file : String,
      @absolute_path : String,
      @source_path : String,
      @source_line : Int32,
      @source : String,
      @line_offset : Int32,
      @exports : Array(String),
      @references : Array(String),
      @component : MochiComponent? = nil,
      @helper : HelperUnit? = nil,
      @dependencies : Array(String) = [] of String,
      @resources : Array(String) = [] of String,
      @capabilities : Array(String) = [] of String,
      @method_calls : Array(String) = [] of String,
    )
    end

    def component? : Bool
      @kind == "component"
    end

    def location : String
      return @source_path if @source_line <= 0
      "#{@source_path}:#{@source_line}"
    end
  end

  class PackageGraph
    getter packages : Hash(String, PackageNode)
    getter entry_packages : Array(String)
    getter order : Array(String)
    getter component_order : Array(MochiComponent)
    getter capabilities : Hash(String, Capability)

    def initialize(
      @packages : Hash(String, PackageNode),
      @entry_packages : Array(String),
      @order : Array(String),
      @component_order : Array(MochiComponent),
      @capabilities : Hash(String, Capability),
    )
    end

    def self.build(
      components : Array(MochiComponent),
      prelude_sources : Array(PreludeSource),
      helpers : Array(HelperUnit),
      search_roots : Array(String),
      project_root : String? = nil,
    ) : PackageGraph
      packages = {} of String => PackageNode
      absolute_to_package = {} of String => String

      prelude_sources.each do |source|
        id = ruby_package_id(source.source_path)
        add_package(packages, absolute_to_package, build_ruby_package(id, source))
      end

      helper_by_key = {} of String => HelperUnit
      helpers.each do |helper|
        helper_by_key[helper.key] = helper
        id = helper_package_id(helper.origin)
        add_package(packages, absolute_to_package, build_helper_package(id, helper))
      end

      components.each do |component|
        id = component_package_id(component.manifest.tag_name)
        node = build_component_package(id, component)
        if helper_chi = component.manifest.helper_chi
          helper = helper_by_key[helper_chi]?
          unless helper
            raise "Component '#{component.manifest.tag_name}' references missing helper package '#{helper_chi}' at #{component_location(component)}"
          end
          node.dependencies << helper_package_id(helper.origin)
          absolute_to_package[normalize_absolute(component.absolute_path)] = helper_package_id(helper.origin)
        else
          absolute_to_package[normalize_absolute(component.absolute_path)] = id
        end
        add_package(packages, absolute_to_package, node)
      end

      graph = new(packages, [] of String, [] of String, [] of MochiComponent, {} of String => Capability)
      graph.resolve_dependencies(search_roots, project_root)
      graph.resolve_entries_and_order(components, project_root)
      graph.resolve_capabilities
      graph.sync_components
      graph
    end

    private def self.add_package(
      packages : Hash(String, PackageNode),
      absolute_to_package : Hash(String, String),
      node : PackageNode,
    ) : Nil
      if previous = packages[node.id]?
        raise "duplicate package '#{node.id}' at #{previous.location} and #{node.location}"
      end
      packages[node.id] = node
      unless node.absolute_path.empty?
        absolute_to_package[normalize_absolute(node.absolute_path)] = node.id
      end
    end

    private def self.build_ruby_package(id : String, source : PreludeSource) : PackageNode
      symbols = TreeSitter::SourceSymbolExtractor.extract(source.source)
      PackageNode.new(
        id,
        "ruby",
        "ruby-#{digest(id)}.chi",
        source.absolute_path,
        source.source_path,
        1,
        source.source,
        1,
        symbols.exports,
        symbols.references,
        method_calls: symbols.method_calls
      )
    end

    private def self.build_helper_package(id : String, helper : HelperUnit) : PackageNode
      symbols = TreeSitter::SourceSymbolExtractor.extract(helper.source)
      PackageNode.new(
        id,
        "ruby",
        helper.key,
        helper.absolute_path || "",
        helper.origin,
        1,
        helper.source,
        1,
        symbols.exports,
        symbols.references,
        helper: helper,
        method_calls: symbols.method_calls
      )
    end

    private def self.build_component_package(id : String, component : MochiComponent) : PackageNode
      source = component.original_source.empty? ? component.ruby_code : component.original_source
      symbols = TreeSitter::SourceSymbolExtractor.extract(source)
      # Lowered row conditions, slots and event arguments no longer appear in
      # HTML. Discover their dependencies from the Ruby that will execute.
      generated = source == component.ruby_code ? symbols : TreeSitter::SourceSymbolExtractor.extract(component.ruby_code)
      exports = symbols.exports.dup
      exports << component.manifest.class_name unless exports.includes?(component.manifest.class_name)
      PackageNode.new(
        id,
        "component",
        component.manifest.chi_file,
        component.absolute_path,
        component.source_path,
        component.manifest.source_line,
        source,
        component.source_line_offset,
        exports.uniq.sort,
        (symbols.references + generated.references).uniq,
        component: component,
        resources: component.manifest.style_resource_ids.dup,
        method_calls: (symbols.method_calls + generated.method_calls).uniq
      )
    end

    def self.ruby_package_id(source_path : String) : String
      "ruby:#{normalize_logical_path(source_path)}"
    end

    def self.helper_package_id(source_path : String) : String
      "helper:#{normalize_logical_path(source_path)}"
    end

    def self.component_package_id(tag_name : String) : String
      "component:#{tag_name}"
    end

    def self.normalize_logical_path(path : String) : String
      normalized = path.gsub('\\', '/')
      normalized = normalized.lchop("./")
      normalized
    end

    def self.normalize_absolute(path : String) : String
      return "" if path.empty?
      File.expand_path(path)
    end

    private def self.digest(value : String) : String
      Digest::SHA1.hexdigest(value)[0, 12]
    end

    private def self.component_location(component : MochiComponent) : String
      return component.source_path if component.class_line <= 0
      "#{component.source_path}:#{component.class_line}"
    end

    def package(id : String) : PackageNode?
      @packages[id]?
    end

    def ruby_order : Array(PackageNode)
      @order.compact_map do |id|
        node = @packages[id]?
        node if node && !node.component?
      end
    end

    def has_capability?(name : String) : Bool
      @capabilities.has_key?(name)
    end

    def capability_package_ids : Set(String)
      result = Set(String).new
      @capabilities.each_value { |capability| capability.packages.each { |id| result << id } }
      result
    end

    def resolve_dependencies(search_roots : Array(String), project_root : String?) : Nil
      roots = search_roots.map { |root| self.class.normalize_absolute(root) }.reject(&.empty?)
      if project_root
        root = self.class.normalize_absolute(project_root)
        roots << root unless roots.includes?(root)
      end

      export_index = {} of String => Array(PackageNode)
      @packages.each_value do |node|
        node.exports.each do |name|
          list = export_index[name] ||= [] of PackageNode
          list << node
        end
      end

      @packages.each_value do |node|
        resolve_requires(node, roots, export_index)
        resolve_constants(node, export_index)
        if node.component?
          resolve_component_tags(node)
        end
        collections_id = self.class.ruby_package_id("lib/mochi_builtin_collections.rb")
        if @packages.has_key?(collections_id) && node.method_calls.any? { |name| name.in?("sum", "min", "max") }
          node.dependencies << collections_id unless node.id == collections_id
        end
        node.dependencies = node.dependencies.reject(&.==(node.id)).uniq.sort
      end
    end

    private def resolve_requires(
      node : PackageNode,
      roots : Array(String),
      export_index : Hash(String, Array(PackageNode)),
    ) : Nil
      imports = TreeSitter::ImportsExtractor.extract_import_calls(node.source, node.source_path)
      imports.each do |import|
        target = resolve_import(node, import, roots, export_index)
        node.dependencies << target if target
      end
    end

    private def resolve_import(
      node : PackageNode,
      import : TreeSitter::ImportCall,
      roots : Array(String),
      export_index : Hash(String, Array(PackageNode)),
    ) : String?
      relative = import.method == "require_relative" ||
                 import.path.starts_with?("./") ||
                 import.path.starts_with?("../")

      candidates = [] of String
      names = [import.path]
      names << "#{import.path}.rb" unless import.path.ends_with?(".rb")

      if relative
        base = node.absolute_path.empty? ? Dir.current : File.dirname(node.absolute_path)
        names.each { |name| candidates << File.expand_path(name, base) }
      else
        names.each do |name|
          roots.each { |root| candidates << File.expand_path(name, root) }
          unless node.absolute_path.empty?
            candidates << File.expand_path(name, File.dirname(node.absolute_path))
          end
        end
      end

      resolved = candidates.compact_map { |candidate| package_id_for_absolute(candidate) }.uniq
      if resolved.size > 1
        raise "ambiguous Ruby dependency '#{import.path}' at #{node.source_path}:#{import.line}: " \
              "#{resolved.sort.join(", ")}"
      end
      return resolved.first unless resolved.empty?

      if import.method == "require" && import.path.in?("json", "time")
        builtin = @packages["ruby:lib/mochi_builtin_#{import.path}.rb"]?
        return builtin.id if builtin
      end

      if import.method == "require" && RUNTIME_REQUIRES.includes?(import.path)
        return nil
      end

      raise "missing Ruby dependency '#{import.path}' required at #{node.source_path}:#{import.line}"
    end

    # The absolute path index is rebuilt here because the package graph only
    # keeps logical paths. It is cheap and keeps the public package data free of
    # build-local absolute paths.
    private def package_id_for_absolute(candidate : String) : String?
      normalized = self.class.normalize_absolute(candidate)
      @packages.each_value do |node|
        next if node.absolute_path.empty?
        return node.id if self.class.normalize_absolute(node.absolute_path) == normalized
      end
      nil
    end

    private def resolve_constants(
      node : PackageNode,
      export_index : Hash(String, Array(PackageNode)),
    ) : Nil
      own_exports = node.exports.to_set
      references = node.references.dup
      if component = node.component
        references.concat(template_constant_references(component))
      end
      references.uniq.each do |reference|
        next if own_exports.includes?(reference)
        candidates = export_index[reference]?
        next unless candidates

        others = candidates.reject { |candidate| candidate.id == node.id }.uniq { |candidate| candidate.id }
        next if others.empty?
        if others.size > 1
          locations = others.map(&.location).sort.join(", ")
          raise "duplicate Ruby constant '#{reference}' owned by #{locations}; keep one package boundary"
        end
        node.dependencies << others.first.id
      end
    end

    # Template expressions are strings in the Ruby source, so tree-sitter sees
    # their constant references as text. Scan the emitted template fragments so
    # helpers such as MochiIcons become dependencies of the component that uses
    # them instead of an eagerly loaded prelude.
    private def template_constant_references(component : MochiComponent) : Array(String)
      references = [] of String
      component_template_text(component).each do |text|
        text.scan(/\b[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*/) do |match|
          name = match[0]
          references << name unless references.includes?(name)
          root = name.split("::").first
          references << root unless references.includes?(root)
        end
      end
      references
    end

    private def resolve_component_tags(node : PackageNode) : Nil
      component = node.component.not_nil!
      tag_index = @packages.values.select(&.component?).to_h { |candidate| {candidate.component.not_nil!.manifest.tag_name, candidate} }
      tags = [] of String
      # Only child tags in the always-rendered template are eager package
      # dependencies. Tags inside conditionals or list rows mount later, so
      # their bytecode belongs to the child's own first-use load. This is what
      # keeps a route-owned screen out of the shell's initial request closure.
      [component.manifest.html_template].each do |text|
        text.scan(/<([A-Za-z][A-Za-z0-9-]*)\b/) do |match|
          tag = match[1]
          tags << tag unless tags.includes?(tag)
        end
      end

      tags.sort.each do |tag|
        next if tag == component.manifest.tag_name
        if candidate = tag_index[tag]?
          node.dependencies << candidate.id
        end
      end
    end

    private def component_template_text(component : MochiComponent) : Array(String)
      texts = [] of String
      texts << component.manifest.html_template
      component.manifest.all_bindings.each do |binding|
        if text = binding.template_text
          texts << text
        end
        binding.branches.each { |branch| texts << branch.html_template }
        if rows = binding.each_rows
          collect_each_row_templates(rows, texts)
        end
      end
      texts
    end

    private def collect_each_row_templates(rows : EachRowFragment, texts : Array(String)) : Nil
      rows.each_template { |fragment| texts << fragment.template }
    end

    def resolve_entries_and_order(components : Array(MochiComponent), project_root : String?) : Nil
      roots = entry_components(components, project_root)
      @entry_packages = roots.map { |component| self.class.component_package_id(component.manifest.tag_name) }.sort
      component_packages = @packages.values.select(&.component?).map(&.id).sort
      reachable = reachable_packages(component_packages)
      order = topological_order(reachable.to_a)
      @order = order.select { |id| reachable.includes?(id) }
      @component_order = @order.compact_map do |id|
        node = @packages[id]?
        node ? node.component : nil
      end
      validate_duplicate_exports(reachable)
    end

    private def entry_components(components : Array(MochiComponent), project_root : String?) : Array(MochiComponent)
      return components unless project_root

      html_paths = [File.join(project_root, "index.html")]
      html_paths.concat(Dir.glob(Path[project_root, "public", "**", "*.{html,htm}"].to_s))
      sources = html_paths.select { |path| File.file?(path) }.map { |path| File.read(path) }
      return components if sources.empty?

      roots = components.select do |component|
        tag = component.manifest.tag_name
        pattern = Regex.new("(?i)<\\s*#{Regex.escape(tag)}(?:[\\s/>])")
        sources.any? { |source| pattern.matches?(source) }
      end
      roots.empty? ? components : roots
    end

    private def reachable_packages(entries : Array(String)) : Set(String)
      seen = Set(String).new
      pending = entries.dup
      until pending.empty?
        id = pending.pop
        next if seen.includes?(id)
        node = @packages[id]?
        unless node
          raise "missing dependency package '#{id}'"
        end
        seen << id
        pending.concat(node.dependencies)
      end
      seen
    end

    private def topological_order(ids : Array(String)) : Array(String)
      state = {} of String => Int32
      stack = [] of String
      order = [] of String

      visit = uninitialized Proc(String, Nil)
      visit = ->(id : String) do
        if state[id]? != 2
          if state[id]? == 1
            start = stack.index(id) || 0
            cycle = stack[start..] + [id]
            details = cycle.map do |member|
              node = @packages[member]?
              node ? "#{member} (#{node.location})" : member
            end.join(" -> ")
            raise "dependency cycle: #{details}"
          end

          node = @packages[id]?
          raise "missing dependency package '#{id}'" unless node

          state[id] = 1
          stack << id
          node.dependencies.sort.each { |dependency| visit.call(dependency) }
          stack.pop
          state[id] = 2
          order << id
        end
      end

      ids.sort.each { |id| visit.call(id) }
      order
    end

    private def validate_duplicate_exports(reachable : Set(String)) : Nil
      owners = {} of String => Array(PackageNode)
      @packages.each_value do |node|
        next unless reachable.includes?(node.id)
        node.exports.each do |name|
          list = owners[name] ||= [] of PackageNode
          list << node
        end
      end

      owners.each do |name, nodes|
        next if nodes.size <= 1
        locations = nodes.map(&.location).sort.join(", ")
        raise "duplicate Ruby constant '#{name}' owned by #{locations}; keep one package boundary"
      end
    end

    def resolve_capabilities : Nil
      @capabilities = {} of String => Capability
      component_packages = @packages.values.select(&.component?).map(&.id)
      reachable = reachable_packages(component_packages)
      CAPABILITY_DEFINITIONS.each do |definition|
        active_packages = @packages.values
          .select do |node|
            next false unless reachable.includes?(node.id)
            if definition.name == "network"
              node.source.includes?("Mochi.fetch") || node.source.includes?("Mochi.cancel_fetch")
            else
              node.exports.includes?(definition.exporting)
            end
          end
          .map(&.id)
          .sort
        next if active_packages.empty?

        @capabilities[definition.name] = Capability.new(
          definition.name,
          definition.version,
          definition.host,
          definition.operations,
          active_packages,
          definition.limit_keys
        )
      end
    end

    # Legacy callers can request a capability explicitly instead of relying on
    # an exporting package. Keep the manifest shape identical either way.
    def ensure_capability(name : String) : Nil
      return if @capabilities.has_key?(name)
      definition = CAPABILITY_DEFINITIONS.find { |candidate| candidate.name == name }
      return unless definition

      @capabilities[name] = Capability.new(
        definition.name,
        definition.version,
        definition.host,
        definition.operations,
        [] of String,
        definition.limit_keys
      )
    end

    def sync_components : Nil
      @packages.values.compact_map(&.component).each do |component|
        node = @packages[self.class.component_package_id(component.manifest.tag_name)]?
        next unless node

        closure = reachable_from(node.id)
        @capabilities.each_value do |capability|
          next unless capability.packages.any? { |id| closure.includes?(id) }
          node.capabilities << capability.name
        end
        node.capabilities = node.capabilities.uniq.sort

        component.manifest.package_id = node.id
        component.manifest.dependencies = node.dependencies
        component.manifest.capabilities = node.capabilities
        component.manifest.formatting = node.capabilities.includes?("formatting")
      end
    end

    private def reachable_from(id : String) : Set(String)
      reachable_packages([id])
    end
  end
end
