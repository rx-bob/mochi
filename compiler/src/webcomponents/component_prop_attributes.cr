require "./binding_manifest"
require "../html/each_row_compiler"

# Once the component inventory is known, declared child props take precedence
# over HTML presence/absence semantics (e.g. required=false must stay present).
# The decision stays in descriptors, without loading child code or schemas early.
class ComponentPropAttributes
  def self.apply(manifests : Array(ComponentManifest)) : Nil
    props = {} of String => Array(String)
    manifests.each do |manifest|
      names = manifest.props.map(&.name).map { |name| name.gsub('_', '-') }
        .select { |name| HtmlAttributes.kind(name) == "boolean" }
      props[manifest.tag_name] = names unless names.empty?
    end
    return if props.empty?
    manifests.each { |manifest| resolve(manifest.html_template, manifest.bindings, EachRowDomContext.new, props) }
  end

  private def self.resolve(html : String, bindings : Array(BindingDescriptor), context : EachRowDomContext,
                           props : Hash(String, Array(String)))
    root = EachRowCompiler.fragment_root(html, context)
    bindings.map! do |binding|
      if binding.kind == "attr" && (name = binding.attr_name) && root
        node = root
        binding.path.each { |index| node = node.try(&.children.to_a[index]?) }
        if node && props[node.tag_name]?.try(&.includes?(name))
          binding.attr_kind = "text"
        end
      end
      binding.branches.each do |branch|
        resolve(branch.html_template, branch.bindings, EachRowDomContext.new(branch.context_tag, branch.context_namespace), props)
      end
      if row = binding.each_rows
        row.each_template do |fragment|
          slots = [] of Int32
          TemplateAttributes.scan(fragment.template).each do |attribute|
            next unless props[attribute.tag.downcase]?.try(&.includes?(attribute.name.downcase))
            attribute.value(fragment.template).scan(EachRowCompiler::SENTINEL_PATTERN) { |match| slots << match[1].to_i }
          end
          fragment.bindings.map! do |slot|
            slot.attr_kind = "text" if slots.includes?(slot.slot) && slot.kind == "attr"
            slot
          end
        end
      end
      binding
    end
  end
end
