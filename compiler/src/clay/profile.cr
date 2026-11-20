require "string_scanner"
require "../html/template_expression"
require "../ruby/ruby_def"
require "../tree-sitter/ruby_parser"
require "../tooling/portable_project"
require "../webcomponents/style_composer"

enum RenderTarget
  Dom
  Desktop
end

# Validate the inspector subset against the original Ruby literals and the
# authored CSS sources, including markup that mounts only in a later state.
class ClayProfile
  getter rules = [] of Tuple(String, Hash(String, String))
  getter fonts = {} of String => String
  @child_use : Tuple(Int32, String)?

  # VM-only operations shared by the two hosts. Add host-backed operations
  # when both hosts implement them.
  SHARED_MOCHI_OPERATIONS = Set{"json_parse", "json_generate", "time_at"}

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

  def validate_template(known_tags : Set(String), capability_receivers : Set(String)) : Nil
    html, line = literal(@html_method)
    validate_html(html, line, known_tags, capability_receivers)
  end

  def compose_styles(absolute_path : String, staged_root : String, assets : Hash(String, String)) : CssComposition
    css, line = @css_method.try { |method| literal(method) } || {"", 1}
    composition = StyleComposer.new(@component, absolute_path, @path, staged_root).compose(css, line)
    composition.sources.each { |source| parse_styles(source, assets) }
    composition
  end

  private def parse_styles(source : CssSource, assets : Hash(String, String)) : Nil
    css = source.text
    scan = StringScanner.new(css)
    until scan.eos?
      scan.skip(/(?:\s+|\/\*.*?\*\/)+/m)
      break if scan.eos?
      at = scan.byte_offset
      selector = scan.scan(/\.[a-zA-Z_][\w-]*/)
      unless selector && scan.skip(/\s*\{/)
        reject(source.path, line_at(css, at, source.line), "expected a single class selector")
      end
      declarations = {} of String => String
      @rules << {selector[1..], declarations}
      loop do
        scan.skip(/(?:\s+|\/\*.*?\*\/)+/m)
        break if scan.skip('}')
        at = scan.byte_offset
        name = scan.scan(/[a-z-]+/)
        unless name && scan.skip(/\s*:\s*/) && (raw = scan.scan(/[^{};]+/))
          reject(source.path, line_at(css, at, source.line), "invalid style declaration")
        end
        value = raw.strip
        unless supported_style?(name, value)
          reject(source.path, line_at(css, at, source.line), "unsupported CSS '#{name}: #{value}'")
        end
        if name == "font-family"
          family = value.split(',').first.strip
          unless family.in?("sans-serif", "monospace")
            asset = assets[family]? || reject(source.path, line_at(css, at, source.line), "font family '#{family}' is missing from #{PortableProject::FILE_NAME}")
            @fonts[family] = asset
          end
        end
        declarations[name] = value
        scan.skip(';')
      end
    end
  end

  private def supported_style?(name : String, value : String) : Bool
    case name
    when "display"                   then value == "flex"
    when "flex-direction"            then value.in?("column", "row")
    when "color", "background-color" then value.matches?(/\A#[0-9a-fA-F]{6}\z/)
    when "width", "height", "gap", "padding", "font-size", "line-height"
      value.matches?(/\A(?:[0-9]{1,4}px|0)\z/)
    when "font-family"      then value.matches?(/\A[a-zA-Z][\w-]*(?:,\s*(?:sans-serif|monospace))?\z/)
    when "font-weight"      then value.in?("400", "500", "600", "700")
    when "text-align"       then value == "left"
    when "box-sizing"       then value == "border-box"
    when "border", "margin" then value == "0"
    else                         false
    end
  end

  private def validate_html(html : String, line : Int32, known_tags : Set(String), capability_receivers : Set(String)) : Nil
    scan = StringScanner.new(html)
    parents = [] of String
    until scan.eos?
      at = scan.byte_offset
      if scan.skip(/\s+/) || scan.skip(/<!--.*?-->/m)
        next
      elsif scan.skip("</")
        name = scan.scan(/[\w-]+/)
        reject(@path, line_at(html, at, line), "mismatched closing tag") unless name && parents.pop? == name && scan.skip(/\s*>/)
      elsif scan.skip('<')
        name = scan.scan(/[\w:-]+/)
        unless name && name.in?("div", "span", "button")
          unless name && known_tags.includes?(name)
            reject(@path, line_at(html, at, line), "unsupported element <#{name}>")
          end
          @child_use ||= {line_at(html, at, line), name}
        end
        reject(@path, line_at(html, at, line), "span and button accept text only") if parents.last?.in?("span", "button")
        parents << name
        validate_attributes(scan, html, line, name, capability_receivers)
      elsif scan.check('{')
        token = placeholder(scan, html, line, capability_receivers)
        unless token.matches?(/\A\{(?:if\s|elsif\s|each\s|else\}|end\})/) || parents.last?.in?("span", "button")
          reject(@path, line_at(html, at, line), "put text in a span or button")
        end
      else
        reject(@path, line_at(html, at, line), "put text in a span or button") unless parents.last?.in?("span", "button")
        scan.skip(/[^<{]+/)
      end
    end
    reject(@path, line_at(html, html.bytesize, line), "unclosed <#{parents.last}>") unless parents.empty?
  end

  private def validate_attributes(scan, html, line, tag, capability_receivers)
    loop do
      scan.skip(/\s+/)
      break if scan.skip('>')
      at = scan.byte_offset
      name = scan.scan(/[\w:.-]+/)
      unless name && (name == "class" || name.matches?(/\A(?:aria-|data-(?!mochi-))[a-z][a-z0-9-]*\z/) || (name == "onclick" && tag == "button"))
        reject(@path, line_at(html, at, line), "unsupported attribute '#{name}' on <#{tag}>")
      end
      unless scan.skip(/\s*=\s*/) && (quote = scan.scan(/["']/))
        reject(@path, line_at(html, at, line), "expected a quoted attribute value")
      end
      until scan.skip(quote)
        reject(@path, line_at(html, at, line), "unterminated attribute") if scan.eos?
        if scan.check('{')
          placeholder(scan, html, line, capability_receivers)
        else
          scan.scan(/[^{"']+/) || scan.scan(1)
        end
      end
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
    self.class.validate_ruby(expression, @path, line_at(html, at, line), @component, capability_receivers)
    token
  end

  def reject_child! : Nil
    if use = @child_use
      reject(@path, use[0], "child component <#{use[1]}> is outside the current portable profile")
    end
  end

  def self.validate_ruby(source : String, path : String, line : Int32, component : String, capability_receivers : Set(String)) : Nil
    return unless source.includes?("Mochi") || capability_receivers.any? { |receiver| source.includes?(receiver) }

    tree = TreeSitter::RubyParser.new.parse(source)
    check_calls(tree.root_node, path, line, component, capability_receivers)
  end

  private def self.check_calls(node, path, line, component, capability_receivers) : Nil
    if node.type == "call"
      receiver = node.child_by_field_name("receiver").try(&.text.lchop("::"))
      method = node.child_by_field_name("method").try(&.text)
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
    node.each_named_child { |child| check_calls(child, path, line, component, capability_receivers) }
  end

  private def line_at(text : String, offset : Int32, line : Int32 = 1) : Int32
    line + text.byte_slice(0, offset).count('\n')
  end

  private def reject(path : String, line : Int32, message : String) : NoReturn
    raise "#{path}:#{line}: portable component '#{@component}': #{message}"
  end
end
