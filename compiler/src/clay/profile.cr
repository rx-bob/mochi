require "string_scanner"
require "../html/template_expression"
require "../ruby/ruby_def"

enum RenderTarget
  Dom
  Desktop
end

# Parse the deliberately small portable grammar before HTML error recovery or
# CSS composition could discard an unsupported construct and change its meaning.
class ClayProfile
  getter rules = [] of Tuple(String, Hash(String, String))

  def initialize(@source : String, @path : String)
  end

  # Mochi normalizes template whitespace for code generation. Validate the
  # original literal bytes so diagnostics keep their authored Ruby lines.
  private def literal(method : RubyDef) : Tuple(String, Int32)
    start = method.raw_string_start
    finish = method.raw_string_end
    unless start && finish
      raise "#{@path}:#{method.start_line}: desktop target: expected a literal #{method.name} body"
    end
    {@source.byte_slice(start, finish - start), start}
  end

  def validate_template(method : RubyDef) : Nil
    html, start = literal(method)
    validate_html(html, start)
  end

  def parse_styles(method : RubyDef?) : Nil
    return unless method
    css, start = literal(method)
    scan = StringScanner.new(css)
    until scan.eos?
      scan.skip(/(?:\s+|\/\*.*?\*\/)+/m)
      break if scan.eos?
      selector = scan.scan(/\.[a-zA-Z_][\w-]*/)
      unless selector && scan.skip(/\s*\{/)
        error(start + scan.byte_offset, "expected a single class selector")
      end
      declarations = {} of String => String
      @rules << {selector[1..], declarations}
      loop do
        scan.skip(/(?:\s+|\/\*.*?\*\/)+/m)
        break if scan.skip('}')
        at = scan.byte_offset
        name = scan.scan(/[a-z-]+/)
        unless name && scan.skip(/\s*:\s*/) && (raw = scan.scan(/[^{};]+/))
          error(start + at, "invalid style declaration")
        end
        value = raw.strip
        unless supported_style?(name, value)
          error(start + at, "unsupported CSS '#{name}: #{value}'")
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

  def validate_html(html : String, start : Int32) : Nil
    scan = StringScanner.new(html)
    parents = [] of String
    until scan.eos?
      at = scan.byte_offset
      if scan.skip(/\s+/) || scan.skip(/<!--.*?-->/m)
        next
      elsif scan.skip("</")
        name = scan.scan(/[\w-]+/)
        error(start + at, "mismatched closing tag") unless name && parents.pop? == name && scan.skip(/\s*>/)
      elsif scan.skip('<')
        name = scan.scan(/[\w:-]+/)
        error(start + at, "unsupported element <#{name}>") unless name && name.in?("div", "span", "button")
        error(start + at, "span and button accept text only") if parents.last?.in?("span", "button")
        parents << name
        validate_attributes(scan, html, start, name)
      elsif scan.check('{')
        token = placeholder(scan, html, start)
        unless token.matches?(/\A\{(?:if\s|elsif\s|each\s|else\}|end\})/) || parents.last?.in?("span", "button")
          error(start + at, "put text in a span or button")
        end
      else
        error(start + at, "put text in a span or button") unless parents.last?.in?("span", "button")
        scan.skip(/[^<{]+/)
      end
    end
    error(start + html.bytesize, "unclosed <#{parents.last}>") unless parents.empty?
  end

  private def validate_attributes(scan, html, start, tag)
    loop do
      scan.skip(/\s+/)
      break if scan.skip('>')
      at = scan.byte_offset
      name = scan.scan(/[\w:.-]+/)
      unless name && (name == "class" || name.matches?(/\A(?:aria-|data-(?!mochi-))[a-z][a-z0-9-]*\z/) || (name == "onclick" && tag == "button"))
        error(start + at, "unsupported attribute '#{name}' on <#{tag}>")
      end
      unless scan.skip(/\s*=\s*/) && (quote = scan.scan(/["']/))
        error(start + at, "expected a quoted attribute value")
      end
      until scan.skip(quote)
        error(start + at, "unterminated attribute") if scan.eos?
        if scan.check('{')
          placeholder(scan, html, start)
        else
          scan.scan(/[^{"']+/) || scan.scan(1)
        end
      end
    end
  end

  private def placeholder(scan, html, start)
    at = scan.byte_offset
    ending = TemplateExpressionParser.matching_brace(html, at)
    error(start + at, "unclosed template expression") unless ending
    token = html.byte_slice(at, ending - at + 1)
    scan.skip(token)
    error(start + at, "trusted markup is outside the Clay profile") if token.matches?(/Mochi\s*\.\s*raw\b/)
    token
  end

  private def error(at : Int32, message : String) : NoReturn
    line = @source.byte_slice(0, at.clamp(0, @source.bytesize)).count('\n') + 1
    raise "#{@path}:#{line}: desktop target: #{message}"
  end
end
