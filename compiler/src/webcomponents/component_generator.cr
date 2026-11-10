require "lexbor"
require "./binding_manifest"
require "../html/conditional_processor"
require "../html/each_processor"

class ComponentGenerator
  CONTROL_TEMPLATE_PREFIXES = ["if ", "unless ", "elsif ", "each "]
  CONTROL_TEMPLATE_KEYWORDS = ["else", "end"]

  @each_blocks : Array(EachBlock) = [] of EachBlock
  @conditionals : Array(ConditionalBlock) = [] of ConditionalBlock
  @next_binding_id : Int32 = 0
  @next_each_id : Int32 = 0
  @mochi_cmp_name : String = ""

  # Includes top-level and branch-discovered each blocks so callers can inject
  # every generated each helper method after generation.
  getter each_blocks

  def generate(
    mochi_cmp_name : String,
    tag_name : String,
    css : String,
    html : String,
    _reactables : String = "[]",
    _bindings : Hash(String, String) = {} of String => String,
    conditionals : Array(ConditionalBlock) = [] of ConditionalBlock,
    each_blocks : Array(EachBlock) = [] of EachBlock,
    method_names : Array(String) = [] of String,
  ) : ComponentManifest
    @mochi_cmp_name = mochi_cmp_name
    @conditionals = conditionals
    @each_blocks = each_blocks
    @next_binding_id = 0
    @next_each_id = each_blocks.empty? ? 0 : each_blocks.max_of(&.id) + 1

    bindings = [] of BindingDescriptor
    events = [] of EventDescriptor
    html_template = walk_html(html, bindings, events)
    chi_file = "#{tag_name}.chi"

    manifest = ComponentManifest.new(
      tag_name,
      mochi_cmp_name,
      chi_file,
      html_template,
      css,
      bindings,
      events
    )

    validate_template_placeholders(mochi_cmp_name, html_template)
    validate_event_handlers(mochi_cmp_name, manifest.all_events, method_names)
    manifest
  end

  private def walk_html(html : String, bindings : Array(BindingDescriptor), events : Array(EventDescriptor)) : String
    doc = Lexbor.new(html)
    body = doc.body

    if body
      body.children.each_with_index do |child, index|
        walk(child, [index], bindings, events)
      end
    end

    body ? body.inner_html : ""
  end

  def rewrite_ruby(
    ruby_code : String,
    class_name : String,
    manifest : ComponentManifest,
    methods : Hash(String, RubyDef),
  ) : String
    removed = ["html", "css"].compact_map { |name| methods[name]? }
    RubyBindingRewriter.rewrite(ruby_code, class_name, manifest.bindings, removed)
  end

  private def walk(
    node : Lexbor::Node,
    path : Array(Int32),
    bindings : Array(BindingDescriptor),
    events : Array(EventDescriptor),
  )
    tag = node.tag_name

    if tag == "_text"
      collect_text_bindings(node.tag_text, path, bindings)
      return
    end

    if tag == "_em_comment"
      collect_anchor_binding(node.tag_text, path, bindings)
      return
    end

    collect_attribute_bindings(node, path, bindings, events)

    node.children.each_with_index do |child, index|
      walk(child, path + [index], bindings, events)
    end
  end

  private def collect_text_bindings(text : String, path : Array(Int32), bindings : Array(BindingDescriptor))
    text.scan(/\{([^}]+)\}/) do |match|
      expression = match[1].strip
      kind = text.strip == "{#{expression}}" ? "html" : "text"
      bindings << new_binding(path, kind, nil, text, expression)
    end
  end

  private def collect_anchor_binding(
    text : String,
    path : Array(Int32),
    bindings : Array(BindingDescriptor),
  )
    if match = text.match(/if-anchor-(\d+)/)
      id = match[1].to_i
      block = @conditionals.find { |candidate| candidate.id == id }
      return unless block

      binding_id = allocate_binding_id
      branches = block.branches.map { |branch| process_branch(branch) }
      template_text = branches.first?.try(&.html_template) || block.content

      bindings << BindingDescriptor.new(
        binding_id,
        path.dup,
        "cond",
        "__mochi_bind_#{binding_id}",
        nil,
        template_text,
        "__mochi_cond_#{block.id}",
        branches
      )
    elsif match = text.match(/each-anchor-(\d+)/)
      id = match[1].to_i
      block = @each_blocks.find { |candidate| candidate.id == id }
      return unless block

      bindings << new_binding(
        path,
        "each",
        nil,
        block.content,
        block.loop_def.array_name
      )
    end
  end

  private def collect_attribute_bindings(
    node : Lexbor::Node,
    path : Array(Int32),
    bindings : Array(BindingDescriptor),
    events : Array(EventDescriptor),
  )
    return unless node.attributes

    attrs = node.attributes
    additions = [] of Tuple(String, String)
    removals = [] of String

    attrs.each do |name, value|
      if name.starts_with?("bind:")
        attr_name = name[5..]
        additions << {attr_name, value}
        removals << name
        add_attribute_binding(path, attr_name, value, bindings)
      elsif name.starts_with?("data-mochi-")
        next
      elsif name.starts_with?("on")
        event_name = name[2..]
        next if event_name.empty?

        if match = value.match(/\{([^}]+)\}/)
          method_name = match[1].split("(").first.strip
          additions << {"data-mochi-#{event_name}", method_name}
          removals << name
          events << EventDescriptor.new(path, event_name, method_name, event_args(attrs))
        end
      elsif value.includes?("{")
        add_attribute_binding(path, name, value, bindings)
      end
    end

    removals.each { |name| node.attribute_remove(name) }
    additions.each { |name, value| node.attribute_add(name, value) }
  end

  private def add_attribute_binding(
    path : Array(Int32),
    attr_name : String,
    value : String,
    bindings : Array(BindingDescriptor),
  )
    value.scan(/\{([^}]+)\}/) do |match|
      expression = match[1].strip
      bindings << new_binding(path, "attr", attr_name, value, expression)
    end
  end

  # Build one conditional branch fragment and recursively compile any nested
  # conditionals or each blocks it contains. Paths and binding IDs are relative
  # to the branch fragment; IDs themselves are component-global.
  private def process_branch(branch : ConditionalBranch) : ConditionalBranchDescriptor
    html = branch_with_anchors(branch)
    each_result = EachProcessor.process(html, @next_each_id)

    unless each_result.each_blocks.empty?
      @each_blocks.concat(each_result.each_blocks)
      @next_each_id += each_result.each_blocks.size
    end

    branch_bindings = [] of BindingDescriptor
    branch_events = [] of EventDescriptor
    template = walk_html(each_result.html, branch_bindings, branch_events)
    validate_template_placeholders(@mochi_cmp_name, template)
    ConditionalBranchDescriptor.new(template, branch_bindings, branch_events)
  end

  private def branch_with_anchors(branch : ConditionalBranch) : String
    html = branch.content

    branch.children.sort_by { |child| -child.start_pos }.each do |child|
      rel_start = child.start_pos - branch.start_pos
      rel_end = child.end_pos - branch.start_pos
      next if rel_start < 0 || rel_end > html.size || rel_start > rel_end

      html = html[0...rel_start] + "<!--if-anchor-#{child.id}-->" + html[rel_end..-1]
    end

    html
  end

  private def allocate_binding_id : Int32
    id = @next_binding_id
    @next_binding_id += 1
    id
  end

  private def event_args(attrs : Hash(String, String)) : Array(String)
    args = [] of String
    index = 0

    while attrs.has_key?("data-mochi-arg-#{index}")
      raw = attrs["data-mochi-arg-#{index}"].strip
      if raw.starts_with?("{") && raw.ends_with?("}")
        raw = raw[1...-1]
      end
      args << raw
      index += 1
    end

    args
  end

  private def new_binding(
    path : Array(Int32),
    kind : String,
    attr_name : String?,
    template_text : String,
    expression : String,
    branches : Array(ConditionalBranchDescriptor) = [] of ConditionalBranchDescriptor,
  ) : BindingDescriptor
    id = allocate_binding_id
    BindingDescriptor.new(
      id,
      path.dup,
      kind,
      "__mochi_bind_#{id}",
      attr_name,
      template_text,
      normalize_expression(expression),
      branches
    )
  end

  # Strict binding syntax: `{@foo}` reads the instance variable `@foo`,
  # while `{foo}` calls the component method `foo`. Never rewrite one into
  # the other here; validation in Compiler#transpile_component catches
  # method bindings that do not resolve to a component method.
  private def normalize_expression(expression : String) : String
    expression.strip
  end

  private def validate_event_handlers(
    class_name : String,
    events : Array(EventDescriptor),
    method_names : Array(String),
  )
    return if method_names.empty?

    events.each do |event|
      next if method_names.includes?(event.method_sym)

      raise "Component '#{class_name}' has an undefined event handler: on#{event.event}=\"{#{event.method_sym}}\""
    end
  end

  private def validate_template_placeholders(class_name : String, template : String)
    index = 0

    while index < template.size
      char = template[index]

      case char
      when '{'
        close = template.index('}', index + 1)
        unless close
          snippet = template[index, Math.min(40, template.size - index)]
          raise "Component '#{class_name}' contains an unclosed template placeholder: #{snippet}"
        end

        inner = template[(index + 1)...close].strip
        if inner.empty?
          raise "Component '#{class_name}' contains an empty template placeholder '{}'"
        end

        if CONTROL_TEMPLATE_KEYWORDS.includes?(inner) || CONTROL_TEMPLATE_PREFIXES.any? { |prefix| inner.starts_with?(prefix) }
          raise "Component '#{class_name}' contains an uncompiled template block '{#{inner}}'"
        end

        index = close + 1
      when '}'
        raise "Component '#{class_name}' contains a stray '}' in its template"
      else
        index += 1
      end
    end
  end
end
