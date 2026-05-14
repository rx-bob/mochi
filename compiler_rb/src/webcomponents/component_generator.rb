# typed: false
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../lexbor/bindings"
require_relative "../data_models/web_component"
require_relative "../html/conditional_processor"
require_relative "../html/each_processor"

class ComponentGenerator
  extend T::Sig

  class Binding < T::Struct
    const :path, T::Array[Integer]
    const :type, Symbol # :text, :html, :attr, :anchor
    const :value, String
    const :name, T.nilable(String) # attribute name for :attr type

    def self.new(path:, type:, value:, name: nil)
      super
    end
  end

  sig { void }
  def initialize
  end

  sig { returns(String) }
  def generate_static
    ""
  end

  sig do
    params(
      mochi_cmp_name: String,
      tag_name: String,
      css: String,
      html: String,
      reactables: String,
      bindings: T::Hash[String, String],
      conditionals: T::Array[ConditionalBlock],
      each_blocks: T::Array[EachBlock]
    ).returns(WebComponent)
  end
  def generate(mochi_cmp_name, tag_name, css, html, reactables, bindings, conditionals = [], each_blocks = [])
    # 1. Parse HTML and find bindings
    doc = Lexbor::Document.parse(html)
    doc_bindings = T.let([], T::Array[Binding])

    body = doc.body
    if body
      traverse(body, [], doc_bindings)
    end

    # Clean HTML for template
    clean_html = body ? body.inner_html : ""

    # Parse reactables string to array
    react_vars = reactables.gsub(/[\[\]"']/, "").split(",").map(&:strip).reject(&:empty?)

    # 2. Generate JS
    js = +""

    # Template registry must come BEFORE customElements.define so that when
    # connectedCallback fires synchronously during define (for already-connected
    # elements), getTemplate() can find the template.
    js << "if(!window._mochi_templates['#{mochi_cmp_name}']) {\n"
    js << "  const t = document.createElement('template');\n"
    js << "  t.innerHTML = `#{clean_html.gsub("`", "\\`").gsub("${", "\\${")}`;\n"
    js << "  window._mochi_templates['#{mochi_cmp_name}'] = t;\n"

    conditionals.each do |c|
      js << "  const tif#{c.id} = document.createElement('template');\n"
      js << "  tif#{c.id}.innerHTML = `#{c.content.gsub("`", "\\`").gsub("${", "\\${")}`;\n"
      js << "  window._mochi_templates['#{mochi_cmp_name}_if_#{c.id}'] = tif#{c.id};\n"
    end
    each_blocks.each do |e|
      js << "  const teach#{e.id} = document.createElement('template');\n"
      js << "  teach#{e.id}.innerHTML = `#{e.content.gsub("`", "\\`").gsub("${", "\\${")}`;\n"
      js << "  window._mochi_templates['#{mochi_cmp_name}_each_#{e.id}'] = teach#{e.id};\n"
    end
    js << "}\n\n"

    js << "class #{mochi_cmp_name}WebComp extends MochiComponent {\n"
    js << "  constructor() {\n"
    js << "    super();\n"
    js << "    this.element = this;\n"
    js << "    this.rubyComp = Opal.#{mochi_cmp_name}.$new();\n"
    js << "  }\n\n"

    # Mount
    js << "  mount(target) {\n"
    js << "    this.rubyComp.$__mochi_mounted(this);\n"
    js << "    const t = MochiComponent.getTemplate('#{mochi_cmp_name}');\n"
    js << "    const r = t.content.cloneNode(true);\n"
    js << "    this.dom_refs = {};\n"
    js << "    this.anchors = {};\n\n"

    # Event Delegation
    js << "    this.shadow.addEventListener('click', (event) => {\n"
    js << "      const target = event.target.closest('[onclick]');\n"
    js << "      if (target) {\n"
    js << "        const action = target.getAttribute('onclick').replace(/[{}]/g, '');\n"
    js << "        const methodName = action.split('(')[0].trim();\n"
    js << "        const args = [];\n"
    js << "        let i = 0;\n"
    js << "        while (target.hasAttribute('data-mochi-arg-'+i)) {\n"
    js << "          let rawVal = target.getAttribute('data-mochi-arg-'+i);\n"
    js << "          if (rawVal === '$event') {\n"
    js << "            args.push(event);\n"
    js << "          } else if (rawVal === '$element') {\n"
    js << "            args.push(target);\n"
    js << "          } else {\n"
    js << "          let primVal = Number(rawVal);\n"
    js << "          args.push(Number.isFinite(primVal) ? primVal : rawVal);\n"
    js << "        }\n"
    js << "        i++;\n"
    js << "      }\n"
    js << "      if (target.dataset) {\n"
    js << "        args.push(Object.assign({}, target.dataset));\n"
    js << "      }\n"
    js << "      this.rubyComp['$'+methodName](...args);\n"
    js << "      this.updateAll();\n"
    js << "    }\n"
    js << "    });\n"
    js << "    this.shadow.addEventListener('change', (event) => {\n"
    js << "      const target = event.target.closest('input[onchange], select[onchange], textarea[onchange]');\n"
    js << "      if (target) {\n"
    js << "        const action = target.getAttribute('onchange').replace(/[{}]/g, '');\n"
    js << "        const methodName = action.split('(')[0].trim();\n"
    js << "        const args = [];\n"
    js << "        let i = 0;\n"
    js << "        let hasArgs = false;\n"
    js << "        while (target.hasAttribute('data-mochi-arg-'+i)) {\n"
    js << "          hasArgs = true;\n"
    js << "          let rawVal = target.getAttribute('data-mochi-arg-'+i);\n"
    js << "          if (rawVal === '$event') {\n"
    js << "            args.push(event);\n"
    js << "          } else if (rawVal === '$element') {\n"
    js << "            args.push(target);\n"
    js << "          } else {\n"
    js << "          let primVal = Number(rawVal);\n"
    js << "          args.push(Number.isFinite(primVal) ? primVal : rawVal);\n"
    js << "        }\n"
    js << "        i++;\n"
    js << "      }\n"
    js << "      let dataset = target.dataset ? Object.assign({}, target.dataset) : {};\n"
    js << "      if (hasArgs) {\n"
    js << "        args.push(dataset);\n"
    js << "        this.rubyComp['$'+methodName](...args);\n"
    js << "      } else {\n"
    js << "        let val = target.value;\n"
    js << "        if (!isNaN(val) && val !== '' && val !== null) val = Number(val);\n"
    js << "        this.rubyComp['$'+methodName](event, val, dataset);\n"
    js << "      }\n"
    js << "      this.updateAll();\n"
    js << "    }\n"
    js << "    });\n\n"

    # Paths
    doc_bindings.each_with_index do |b, i|
      path_str = "r"
      b.path.each do |idx|
        path_str += ".childNodes[#{idx}]"
      end

      ref_name = "ref_#{i}"
      js << "    const #{ref_name} = #{path_str};\n"

      if b.type == :text
        var_name = b.value.gsub(/[{}]/, "")
        js << "    const #{ref_name}_tmpl = #{ref_name}.textContent;\n"
        js << "    if(!this.dom_refs['#{var_name}']) this.dom_refs['#{var_name}'] = [];\n"
        js << "    this.dom_refs['#{var_name}'].push({node: #{ref_name}, type: 'text', template: #{ref_name}_tmpl});\n"
        js << "    #{ref_name}.textContent = #{ref_name}_tmpl.replace('{#{var_name}}', this.rubyComp.$get_#{var_name}());\n"
      elsif b.type == :html
        var_name = b.value.gsub(/[{}]/, "")
        js << "    const #{ref_name}_span = document.createElement('span');\n"
        js << "    #{ref_name}.parentNode.insertBefore(#{ref_name}_span, #{ref_name});\n"
        js << "    #{ref_name}.parentNode.removeChild(#{ref_name});\n"
        js << "    if(!this.dom_refs['#{var_name}']) this.dom_refs['#{var_name}'] = [];\n"
        js << "    this.dom_refs['#{var_name}'].push({node: #{ref_name}_span, type: 'html'});\n"
        js << "    #{ref_name}_span.innerHTML = this.rubyComp.$get_#{var_name}();\n"
      elsif b.type == :attr
        var_name = b.value.gsub(/[{}]/, "")
        js << "    if(!this.dom_refs['#{var_name}']) this.dom_refs['#{var_name}'] = [];\n"
        js << "    this.dom_refs['#{var_name}'].push({node: #{ref_name}, type: 'attr', name: '#{b.name}'});\n"
        js << "    #{ref_name}.setAttribute('#{b.name}', this.rubyComp.$get_#{var_name}());\n"
      elsif b.type == :anchor
        anchor_id = b.value.gsub(/<!--|-->/, "").strip
        js << "    this.anchors['#{anchor_id}'] = #{ref_name};\n"
      end
    end

    # CSS
    js << "    const style = document.createElement('style');\n"
    js << "    style.textContent = `#{css.gsub("`", "\\`").gsub("${", "\\${")}`;\n"
    js << "    this.shadow.appendChild(style);\n"

    js << "    target.appendChild(r);\n"
    js << "    if (this.rubyComp.$mounted) this.rubyComp.$mounted();\n"
    js << "    this.updateAll();\n"
    js << "  }\n\n"

    # Update Methods
    react_vars.each do |v|
      js << "  update_#{v}(val) {\n"
      js << "    const refs = this.dom_refs['#{v}'];\n"
      js << "    if (refs) {\n"
      js << "      for (const r of refs) {\n"
      js << "        if (r.type === 'text') r.node.textContent = r.template.replace('{#{v}}', val);\n"
      js << "        else if (r.type === 'html') r.node.innerHTML = val;\n"
      js << "        else if (r.type === 'attr') r.node.setAttribute(r.name, val);\n"
      js << "      }\n"
      js << "    }\n"
      js << "  }\n\n"
    end

    # syncAttributes: legacy compat alias so mounted() hooks that call comp.syncAttributes() still work
    js << "  syncAttributes() { this.updateAll(); }\n\n"

    # updateAll: re-read all reactive vars from Ruby and update DOM, then run derived
    js << "  updateAll() {\n"
    react_vars.each do |v|
      js << "    this.update_#{v}(this.rubyComp.$get_#{v}());\n"
    end
    js << "    this.updateDerived();\n"
    js << "  }\n\n"

    # observedAttributes + attributeChangedCallback for initial HTML attribute propagation
    # Do not expose internal computed attribute conditionals as observed attributes
    public_react_vars = react_vars.reject { |v| v.start_with?("__mochi_attr_cond_") || v.start_with?("__mochi_attr_hash_") }
    if public_react_vars.size > 0
      obs_list = public_react_vars.map { |v| "'#{v}'" }.join(", ")
      js << "  static get observedAttributes() { return [#{obs_list}]; }\n\n"
      js << "  attributeChangedCallback(name, oldValue, newValue) {\n"
      js << "    if (oldValue === newValue) return;\n"
      js << "    const setter = '$set_' + name;\n"
      js << "    if (this.rubyComp[setter]) {\n"
      js << "      let val = newValue;\n"
      js << "      if (!isNaN(val) && val !== '' && val !== null) val = Number(val);\n"
      js << "      this.rubyComp[setter](val);\n"
      js << "    }\n"
      js << "    this.updateAll();\n"
      js << "  }\n\n"
    end

    # Derived
    js << "  updateDerived() {\n"
    conditionals.each do |c|
      js << "    this.updateConditional(#{c.id}, '#{mochi_cmp_name}_if_#{c.id}', () => {\n"
      js << "      let res = this.rubyComp.$__mochi_cond_#{c.id}();\n"
      js << "      return res !== false && res !== Opal.nil;\n"
      js << "    });\n"
    end
    each_blocks.each do |e|
      js << "    this.updateEach(#{e.id}, '#{mochi_cmp_name}_each_#{e.id}', () => {\n"
      js << "      let items = this.rubyComp.$__mochi_each_#{e.id}_items();\n"
      js << "      if (items && items.$to_a) return items.$to_a();\n"
      js << "      return items || [];\n"
      js << "    }, (item, index) => this.rubyComp.$__mochi_each_#{e.id}_key(item, index));\n"
    end
    js << "  }\n"
    js << "}\n"
    js << "customElements.define('#{tag_name}', #{mochi_cmp_name}WebComp);\n"

    doc.destroy if doc.respond_to?(:destroy)

    WebComponent.new(name: "#{mochi_cmp_name}WebComp", js_code: js)
  end

  # Walk the Lexbor DOM tree and build a list of Binding objects.
  # Text nodes, comment nodes (anchors), and element attributes are scanned
  # for reactive patterns.  Attributes that start with "bind:" are handled
  # specially (the prefix is stripped and the attribute is removed from the
  # DOM).  Children are recursed into with path indices that reflect ALL
  # childNodes (text, comment, element) so that runtime childNode access matches.
  sig do
    params(
      node: Lexbor::Node,
      path: T::Array[Integer],
      bindings: T::Array[Binding]
    ).void
  end
  def traverse(node, path, bindings)
    tag = node.tag_name

    if tag == "_text"
      text = node.tag_text
      if text =~ /\{([^}]+)\}/
        var_name = $1
        # Pure variable nodes (e.g. "\n  {rendered_svg}\n") use innerHTML to allow HTML/SVG content
        binding_type = text.strip == "{#{var_name}}" ? :html : :text
        bindings << Binding.new(path: path, type: binding_type, value: "{#{var_name}}")
      end
    elsif tag == "_em_comment"
      text = node.tag_text
      if text && (text.include?("if-anchor") || text.include?("each-anchor"))
        bindings << Binding.new(path: path, type: :anchor, value: text)
      end
    else
      attrs = node.attributes
      if attrs
        remove_attrs = []
        attrs.each do |k, v|
          if k.start_with?("bind:")
            attr_name = k[5..]
            var_name = v.gsub(/[{}]/, "")
            bindings << Binding.new(path: path, type: :attr, value: "{#{var_name}}", name: attr_name)
            remove_attrs << k
          elsif k.start_with?("on")
            # Event handler attribute — leave in HTML for event delegation, don't treat as reactive binding
          elsif v =~ /\{([^}]+)\}/
            var_name = $1
            bindings << Binding.new(path: path, type: :attr, value: "{#{var_name}}", name: k)
            remove_attrs << k
          end
        end
        remove_attrs.each { |k| node.attribute_remove(k) }
      end

      children = node.children
      if children
        children.each_with_index do |child, i|
          traverse(child, path + [i], bindings)
        end
      end
    end
  end
end
