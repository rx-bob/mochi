require "html"
require "./portable_template"
require "string_scanner"
require "../html/template_expression"
require "../ruby/ruby_def"
require "../tree-sitter/ruby_parser"
require "../tooling/portable_project"
require "./portable_styles"

enum RenderTarget
  Dom
  Desktop
end

# Validate the inspector subset against the original Ruby literals and the
# authored CSS sources, including markup that mounts only in a later state.
class ClayProfile
  getter editing = false
  getter uses_storage = false
  getter styles = PortableStyles.new
  getter source_marks = [] of PortableTemplate::SourceMark

  # VM-only operations shared by the two hosts. Add host-backed operations
  # when both hosts implement them.
  STORAGE_OPERATIONS = Set{"storage_get", "get_storage", "storage_set", "set_storage",
                           "storage_remove", "remove_storage", "storage_subscribe"}
  SHARED_MOCHI_OPERATIONS = Set{"json_parse", "json_generate", "time_at"} | STORAGE_OPERATIONS

  def initialize(
    @source : String,
    @path : String,
    @component : String,
    @html_method : RubyDef,
    @css_method : RubyDef?,
  )
  end

  private def literal(method : RubyDef) : Tuple(String, Int32)
    start = method.raw_string_start
    finish = method.raw_string_end
    unless start && finish
      reject(@path, method.start_line, "expected a literal #{method.name} body")
    end
    {@source.byte_slice(start, finish - start), line_at(@source, start)}
  end

  def validate_template(components : Hash(String, ComponentManifest), capability_receivers : Set(String)) : Nil
    html, line = literal(@html_method)
    validate_html(html, line, components, capability_receivers)
  end

  def compose_styles(absolute_path : String, staged_root : String) : CssComposition
    css, line = @css_method.try { |method| literal(method) } || {"", 1}
    composition = StyleComposer.new(@component, absolute_path, @path, staged_root).compose(css, line)
    resources = composition.resources.map_with_index do |resource, index|
      rules = parse_styles(composition.sources[index])
      @styles.append(rules)
      PortableStyles.resource(PortableStyles.css(rules), resource)
    end
    local_rules = parse_styles(composition.sources.last)
    @styles.append(local_rules)
    CssComposition.new(PortableStyles.css(local_rules), resources, composition.sources)
  end

  private def parse_styles(source : CssSource) : Array(PortableStyleRule)
    rules = [] of PortableStyleRule
    css = source.text
    scan = StringScanner.new(css)
    max_width = nil
    until scan.eos?
      scan.skip(/(?:\s+|\/\*.*?\*\/)+/m)
      break if scan.eos?
      at = scan.byte_offset
      if max_width && scan.skip('}')
        max_width = nil
        next
      end
      if !max_width && scan.scan(/@container\s*\(\s*max-width\s*:\s*([1-9][0-9]{0,3})px\s*\)\s*\{/)
        max_width = scan[1].to_i
        next
      end
      selector = scan.scan(/\.[a-zA-Z_][\w-]*/)
      unless selector && scan.skip(/(?:\s|\/\*.*?\*\/)*\{/m)
        reject(source.path, line_at(css, at, source.line), "expected a single class selector")
      end
      declarations = {} of String => String
      locations = {} of String => String
      rules << PortableStyleRule.new(selector[1..], declarations, locations, max_width)
      loop do
        scan.skip(/(?:\s+|\/\*.*?\*\/)+/m)
        break if scan.skip('}')
        at = scan.byte_offset
        name = scan.scan(/[a-z-]+/)
        unless name && scan.skip(/(?:\s|\/\*.*?\*\/)*:/m) && (raw = scan.scan(/(?:\/\*.*?\*\/|[^{};\/]|\/(?!\*))+/m))
          reject(source.path, line_at(css, at, source.line), "invalid style declaration")
        end
        value = raw.gsub(/\/\*.*?\*\//m, " ").strip
        unless supported_style?(name, value) && (!max_width || name == "flex-direction")
          reject(source.path, line_at(css, at, source.line), "unsupported CSS '#{name}: #{value}'")
        end
        if name.in?("font-family", "font-weight")
          locations[name] = "#{source.path}:#{line_at(css, at, source.line)}"
        end
        declarations[name] = normalize_style(name, value)
        scan.skip(';')
      end
    end
    rules
  end

  private def normalize_style(name : String, value : String) : String
    case name
    when "width", "height", "max-height", "gap", "padding", "font-size", "line-height"
      value == "auto" ? value : "#{value.to_i(strict: false)}px"
    when "color", "background-color"
      value.downcase
    when "font-family"
      value.split(',').map(&.strip).join(", ")
    else
      value
    end
  end

  private def supported_style?(name : String, value : String) : Bool
    case name
    when "display"                   then value == "flex"
    when "flex-direction"            then value.in?("column", "row")
    when "overflow-y"                then value == "auto"
    when "color", "background-color" then value.matches?(/\A#[0-9a-fA-F]{6}\z/)
    when "width", "height"
      value == "auto" || value.matches?(/\A(?:[0-9]{1,4}px|0)\z/)
    when "max-height"
      value.matches?(/\A[0-9]{1,4}px\z/) && value.to_i(strict: false) > 0
    when "gap", "padding", "font-size", "line-height"
      value.matches?(/\A(?:[0-9]{1,4}px|0)\z/)
    when "font-family"
      families = value.split(',').map(&.strip)
      families.all? { |family| family.matches?(/\A[a-zA-Z][\w-]*\z/) } &&
        families[0...-1].none? { |family| family.in?("sans-serif", "monospace") }
    when "font-weight"      then value.matches?(/\A[1-9]00\z/)
    when "text-align"       then value == "left"
    when "box-sizing"       then value == "border-box"
    when "border", "margin" then value == "0"
    else                         false
    end
  end

  private def validate_html(html : String, line : Int32, components : Hash(String, ComponentManifest), capability_receivers : Set(String)) : Nil
    scan = StringScanner.new(html)
    parents = [] of String
    @source_marks.clear
    text_start : Int32? = nil
    until scan.eos?
      at = scan.byte_offset
      if scan.skip(/\s+/)
        next
      elsif scan.skip(/<!--.*?-->/m)
        finish_text(html, text_start, at)
        text_start = nil
      elsif scan.skip("</")
        finish_text(html, text_start, at)
        text_start = nil
        name = scan.scan(/[\w-]+/)
        reject(@path, line_at(html, at, line), "mismatched closing tag") unless name && parents.pop? == name && scan.skip(/\s*>/)
      elsif scan.skip('<')
        finish_text(html, text_start, at)
        text_start = nil
        name = scan.scan(/[\w:-]+/)
        child = name.try { |tag| components[tag]? }
        unless name && (name.in?("div", "span", "button", "label", "input") || child)
          reject(@path, line_at(html, at, line), "unsupported element <#{name}>")
        end
        reject(@path, line_at(html, at, line), "span, label and button accept text only") if parents.last?.in?("span", "button", "label")
        parents << name unless name == "input"
        attrs = validate_attributes(scan, html, line, name, child, capability_receivers)
        validate_editor(name, attrs, line_at(html, at, line)) if name.in?("input", "label")
        mark(name, at, scan.byte_offset)
      elsif scan.check('{')
        if scan.skip("{{")
          reject(@path, line_at(html, at, line), "put text in a span, label or button") unless parents.last?.in?("span", "button", "label")
          text_start ||= at
          next
        end
        token = placeholder(scan, html, line, capability_receivers)
        if token.matches?(/\A\{(?:if\s|elsif\s|each\s|else\}|end\})/)
          finish_text(html, text_start, at)
          text_start = nil
          mark("cond", at, scan.byte_offset) if token.starts_with?("{if")
          mark("each", at, scan.byte_offset) if token.starts_with?("{each")
        else
          reject(@path, line_at(html, at, line), "put text in a span, label or button") unless parents.last?.in?("span", "button", "label")
          text_start ||= at
        end
      else
        reject(@path, line_at(html, at, line), "put text in a span, label or button") unless parents.last?.in?("span", "button", "label")
        text_start ||= at
        scan.skip(/[^<{]+/)
      end
    end
    reject(@path, line_at(html, html.bytesize, line), "unclosed <#{parents.last}>") unless parents.empty?
  end

  private def finish_text(html : String, start : Int32?, finish : Int32) : Nil
    return unless start
    text = html.byte_slice(start, finish - start)
    mark("text", start, finish) unless HTML.unescape(text).strip.empty?
  end

  private def mark(kind : String, from : Int32, to : Int32) : Nil
    start = @html_method.raw_string_start.not_nil!
    @source_marks << PortableTemplate::SourceMark.new(kind,
      TemplateSourceSpan.from_offsets(@source, @path, start + from, start + to))
  end

  private def validate_attributes(scan, html, line, tag, child : ComponentManifest?, capability_receivers)
    attrs = {} of String => String
    loop do
      scan.skip(/\s+/)
      break if scan.skip('>') || (tag == "input" && scan.skip("/>"))
      at = scan.byte_offset
      name = scan.scan(/[\w:.-]+/)
      unless name && (name == "class" || name.matches?(/\A(?:aria-|data-(?!mochi-))[a-z][a-z0-9-]*\z/) ||
             (tag == "button" && name.in?("onclick", "tabindex")) || child_attribute?(name, child) ||
             (tag == "label" && name == "for") ||
             (tag == "input" && name.in?("id", "type", "disabled", "bind:value", "bind:checked", "oninput", "onchange")))
        reject(@path, line_at(html, at, line), "unsupported attribute '#{name}' on <#{tag}>")
      end
      if tag.in?("input", "label") && attrs.has_key?(name)
        reject(@path, line_at(html, at, line), "duplicate #{name} attribute on <#{tag}>")
      end
      if tag == "input" && name == "disabled" && !scan.check(/\s*=/)
        attrs[name] = ""
        next
      end
      unless scan.skip(/\s*=\s*/) && (quote = scan.scan(/["']/))
        reject(@path, line_at(html, at, line), "expected a quoted attribute value")
      end
      start = scan.byte_offset
      until scan.skip(quote)
        reject(@path, line_at(html, at, line), "unterminated attribute") if scan.eos?
        if scan.check('{')
          placeholder(scan, html, line, capability_receivers)
        else
          scan.scan(/[^{"']+/) || scan.scan(1)
        end
      end
      attrs[name] = html.byte_slice(start, scan.byte_offset - start - 1)
      if tag == "button" && name == "tabindex" && attrs[name] != "0"
        reject(@path, line_at(html, at, line), "portable buttons accept only tabindex=\"0\"")
      end
    end
    attrs
  end

  private def validate_editor(tag : String, attrs : Hash(String, String), line : Int32) : Nil
    if tag == "label"
      unless attrs["for"]?.try { |value| !value.strip.empty? }
        reject(@path, line, "portable labels require a for attribute")
      end
      return
    end
    @editing = true
    case attrs["type"]? || "text"
    when "text"
      unless attrs.has_key?("bind:value") && !attrs.has_key?("bind:checked") && !attrs.has_key?("onchange")
        reject(@path, line, "portable text inputs require bind:value and accept an optional oninput handler")
      end
    when "checkbox"
      unless attrs.has_key?("bind:checked") && !attrs.has_key?("bind:value") && !attrs.has_key?("oninput")
        reject(@path, line, "portable checkboxes require bind:checked and accept an optional onchange handler")
      end
    else
      reject(@path, line, "portable inputs support text and checkbox types")
    end
  end

  private def placeholder(scan, html, line, capability_receivers)
    at = scan.byte_offset
    ending = TemplateExpressionParser.matching_brace(html, at)
    reject(@path, line_at(html, at, line), "unclosed template expression") unless ending
    token = html.byte_slice(at, ending - at + 1)
    scan.skip(token)
    reject(@path, line_at(html, at, line), "trusted markup is outside the Clay profile") if token.matches?(/Mochi\s*\.\s*raw\b/)
    expression = token.byte_slice(1, token.bytesize - 2)
    @uses_storage = self.class.validate_ruby(expression, @path, line_at(html, at, line), @component, capability_receivers) || @uses_storage
    token
  end

  def font_error(location : String, reason : String) : NoReturn
    raise "#{location}: portable component '#{@component}': #{reason}"
  end

  private def child_attribute?(name : String, child : ComponentManifest?) : Bool
    return false unless child
    if name.starts_with?("on:")
      child.emits.any? { |event| event.name == name[3..] }
    else
      child.props.any? { |prop| prop.name.gsub('_', '-') == name }
    end
  end

  def self.validate_ruby(source : String, path : String, line : Int32, component : String, capability_receivers : Set(String)) : Bool
    return false unless source.includes?("Mochi") || capability_receivers.any? { |receiver| source.includes?(receiver) }

    tree = TreeSitter::RubyParser.new.parse(source)
    check_calls(tree.root_node, path, line, component, capability_receivers)
  end

  private def self.check_calls(node, path, line, component, capability_receivers) : Bool
    uses_storage = false
    if node.type == "call"
      receiver = node.child_by_field_name("receiver").try(&.text.lchop("::"))
      method = node.child_by_field_name("method").try(&.text)
      uses_storage = receiver == "Mochi" && !!method.try { |name| STORAGE_OPERATIONS.includes?(name) }
      if receiver && method &&
         ((receiver == "Mochi" && !SHARED_MOCHI_OPERATIONS.includes?(method)) || capability_receivers.includes?(receiver))
        operation = "#{receiver}.#{method}"
        if receiver == "Mochi" && method == "host_async" && (args = node.child_by_field_name("arguments"))
          if args.named_child_count >= 2 && args.named_child(0).type == "string" && args.named_child(1).type == "string"
            operation += "(#{args.named_child(0).text}, #{args.named_child(1).text})"
          end
        end
        raise "#{path}:#{line + node.start_point.row.to_i}: portable component '#{component}': unsupported host operation #{operation}"
      end
    end
    node.each_named_child do |child|
      uses_storage = check_calls(child, path, line, component, capability_receivers) || uses_storage
    end
    uses_storage
  end

  private def line_at(text : String, offset : Int32, line : Int32 = 1) : Int32
    line + text.byte_slice(0, offset).count('\n')
  end

  private def reject(path : String, line : Int32, message : String) : NoReturn
    raise "#{path}:#{line}: portable component '#{@component}': #{message}"
  end
end
