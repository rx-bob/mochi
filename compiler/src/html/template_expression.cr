require "../tree-sitter/ruby_parser"

# A location in the original Ruby file. Offsets are not kept in the manifest;
# line/column are enough to point an editor at the offending expression.
struct TemplateSourceSpan
  getter file : String
  getter line : Int32
  getter column : Int32
  getter end_line : Int32
  getter end_column : Int32
  getter length : Int32

  def initialize(
    @file : String,
    @line : Int32,
    @column : Int32,
    @end_line : Int32,
    @end_column : Int32,
    @length : Int32,
  )
  end

  def to_s(io : IO)
    io << file << ":" << line << ":" << column
  end

  def self.from_offsets(source : String, file : String, start_byte : Int32, end_byte : Int32) : TemplateSourceSpan
    start_line, start_column = position(source, start_byte)
    end_line, end_column = position(source, end_byte)
    length = source.byte_slice(start_byte, end_byte - start_byte).size
    new(file, start_line, start_column, end_line, end_column, length)
  end

  private def self.position(source : String, byte_offset : Int32) : Tuple(Int32, Int32)
    offset = byte_offset.clamp(0, source.bytesize)
    prefix = source.byte_slice(0, offset)
    line = 1
    last_newline = -1
    index = 0
    while index < prefix.bytesize
      if prefix.byte_at(index) == 10_u8
        line += 1
        last_newline = index
      end
      index += 1
    end
    column = prefix.byte_slice(last_newline + 1, prefix.bytesize - last_newline - 1).size + 1
    {line, column}
  end
end

class TemplateExpressionError < Exception
  getter span : TemplateSourceSpan?

  def initialize(message : String, @span : TemplateSourceSpan? = nil)
    super(@span ? "#{@span}: #{message}" : message)
  end
end

# One Ruby expression found in a template. `template_start` and `template_end`
# are byte offsets of the whole `{...}` placeholder in the escaped template
# text; `end` is exclusive. The loader uses those offsets instead of guessing
# brace boundaries a second time.
struct TemplateExpression
  getter source : String
  getter template_start : Int32
  getter template_end : Int32
  getter context : String
  getter scope : Array(String)
  getter span : TemplateSourceSpan?

  def initialize(
    @source : String,
    @template_start : Int32,
    @template_end : Int32,
    @context : String,
    @scope : Array(String) = [] of String,
    @span : TemplateSourceSpan? = nil,
  )
  end

  def full_text(template : String) : String
    template.byte_slice(template_start, template_end - template_start)
  end
end

# Maps expression text back to the original Ruby source. The compiler sees a
# transformed HTML string, so searching for the expression text is more robust
# than trying to preserve offsets through every extraction pass.
class TemplateSourceLocator
  @window_start : Int32
  @window_end : Int32

  def initialize(@source : String, @file : String, window_start : Int32 = 0, window_end : Int32? = nil)
    @window_start = window_start.clamp(0, @source.bytesize)
    limit = window_end || @source.bytesize
    @window_end = limit.clamp(@window_start, @source.bytesize)
  end

  def locate(text : String, fallback_offset : Int32 = 0) : TemplateSourceSpan
    search = text
    if start = find_in_window(search)
      return TemplateSourceSpan.from_offsets(@source, @file, start, start + search.bytesize)
    end

    stripped = text.strip
    if !stripped.empty? && (start = find_in_window(stripped))
      return TemplateSourceSpan.from_offsets(@source, @file, start, start + stripped.bytesize)
    end

    start = (@window_start + fallback_offset).clamp(@window_start, @window_end)
    TemplateSourceSpan.from_offsets(@source, @file, start, start)
  end

  private def find_in_window(text : String) : Int32?
    return nil if text.empty?
    window = @source.byte_slice(@window_start, @window_end - @window_start)
    index = window.byte_index(text)
    index ? @window_start + index : nil
  end
end

# One balanced tokenizer for every template context. It understands quotes,
# percent literals, comments, nested braces, and backticks. It does not execute
# or interpret Ruby; syntax validation is delegated to tree-sitter.
#
# Supported template expressions are instance variables, literals, indexed
# hash/array access, and method calls with nested arguments. Conditions, each
# enumerables, and event arguments use the same Ruby validation. Assignments,
# control flow, blocks, method/class definitions and backticks are rejected.
# Ruby string interpolation inside an explicit placeholder remains Ruby;
# bare interpolation outside a placeholder is not template syntax.
class TemplateExpressionParser
  # The only construct that opts a template value into raw markup. It is
  # recognized at compile time so ordinary values, including helper results,
  # always stay text. `Mochi.raw` is a template escape hatch, not a sanitizer:
  # callers must only pass markup they authored or already trust.
  TRUSTED_MARKUP_PREFIX = "Mochi.raw("

  REJECTED_NODE_TYPES = Set{
    "assignment",
    "operator_assignment",
    "subshell",
    "block",
    "do_block",
    "lambda",
    "method",
    "singleton_method",
    "class",
    "module",
    "if",
    "unless",
    "case",
    "while",
    "until",
    "for",
    "begin",
    "rescue",
    "ensure",
    "return",
    "yield",
    "break",
    "next",
    "redo",
    "retry",
    "super",
    "forward_argument",
  }

  @parser : TreeSitter::RubyParser
  @locator : TemplateSourceLocator?

  getter locator

  def initialize(@locator : TemplateSourceLocator? = nil)
    @parser = TreeSitter::RubyParser.new
  end

  def scan(
    template : String,
    context : String,
    scope : Array(String) = [] of String,
    validate : Bool = true,
  ) : Array(TemplateExpression)
    expressions = [] of TemplateExpression
    index = 0

    while index < template.bytesize
      byte = template.byte_at(index)
      if byte == 123_u8 # {
        if index + 1 < template.bytesize && template.byte_at(index + 1) == 123_u8
          index += 2
          next
        end

        close = self.class.matching_brace(template, index)
        unless close
          snippet = template.byte_slice(index, Math.min(40, template.bytesize - index))
          raise TemplateExpressionError.new(
            "unclosed template placeholder near #{snippet.inspect}",
            @locator.try(&.locate(snippet, index))
          )
        end

        start = index + 1
        while start < close && self.class.whitespace?(template.byte_at(start))
          start += 1
        end
        finish = close
        while finish > start && self.class.whitespace?(template.byte_at(finish - 1))
          finish -= 1
        end
        if start == finish
          raise TemplateExpressionError.new(
            "empty template placeholder",
            @locator.try(&.locate(template.byte_slice(index, close - index + 1), index))
          )
        end

        source = template.byte_slice(start, finish - start)
        expression = TemplateExpression.new(
          source,
          index,
          close + 1,
          context,
          scope.dup,
          @locator.try(&.locate(source, index))
        )
        validate!(expression) if validate
        expressions << expression
        index = close + 1
      elsif byte == 125_u8 # }
        if index + 1 < template.bytesize && template.byte_at(index + 1) == 125_u8
          index += 2
          next
        end
        raise TemplateExpressionError.new(
          "stray '}' in template",
          @locator.try(&.locate("}", index))
        )
      elsif byte == 35_u8 && index + 1 < template.bytesize && template.byte_at(index + 1) == 123_u8 # #{
        raise TemplateExpressionError.new(
          %q(Ruby string interpolation #{...} is not supported in templates; use {@ivar} or {helper}),
          @locator.try(&.locate("#" + "{", index))
        )
      else
        index += 1
      end
    end

    expressions
  end

  def parse_call(content : String) : Tuple(String, Array(String))
    text = content.strip
    open = find_unquoted(text, 40)
    return {text, [] of String} unless open

    close = self.class.matching_delimiter(text, open, 40_u8, 41_u8)
    return {text, [] of String} unless close
    return {text, [] of String} unless close == text.bytesize - 1

    method_name = text.byte_slice(0, open).strip
    return {text, [] of String} if method_name.empty?

    {method_name, split_arguments(text.byte_slice(open + 1, close - open - 1))}
  end

  def validate!(expression : TemplateExpression) : Nil
    source = expression.source.strip
    return if source.empty?

    tree = @parser.parse(source)
    root = tree.root_node
    if root.has_error?
      raise TemplateExpressionError.new(
        "invalid Ruby expression #{source.inspect} in #{expression.context}",
        expression.span
      )
    end
    if root.named_child_count != 1
      raise TemplateExpressionError.new(
        "template expression must be one Ruby expression, got #{source.inspect}",
        expression.span
      )
    end
    validate_node(root.named_child(0), expression)
  end

  # Validates an already-tokenized expression such as a conditional or loop
  # enumerable without pretending it is a full `{...}` placeholder.
  def validate_source!(source : String, context : String) : Nil
    span = @locator.try(&.locate(source))
    validate!(TemplateExpression.new(source, 0, source.bytesize, context, [] of String, span))
  end

  # Quoted doubled braces also escape literal braces. A valid Ruby hash or
  # explicit pair/splat syntax selects the hash form; malformed explicit
  # pairs still go through validation rather than silently becoming text.
  def hash_literal_intent?(source : String) : Bool
    tree = @parser.parse(source)
    root = tree.root_node
    return false unless root.named_child_count == 1
    node = root.named_child(0)
    return false unless node.type == "hash"
    return true unless node.has_error?
    node.each_named_child do |child|
      return true if child.type == "pair" || child.type == "hash_splat_argument"
    end
    false
  end

  def split_arguments(text : String) : Array(String)
    self.class.split_arguments(text)
  end

  # Splits a comma-separated Ruby argument list without treating commas inside
  # strings, literals, calls, arrays, or hashes as separators. Loop headers
  # reuse this so `key: f(item, index)` stays one declaration.
  def self.split_arguments(text : String) : Array(String)
    arguments = [] of String
    start = 0
    index = 0
    paren_depth = 0
    bracket_depth = 0
    brace_depth = 0

    while index < text.bytesize
      byte = text.byte_at(index)
      case byte
      when 39_u8, 34_u8, 96_u8 # quotes and backticks
        index = skip_quoted(text, index)
      when 37_u8 # percent literal
        if close = percent_literal_end(text, index)
          index = close
        else
          index += 1
        end
      when 40_u8
        paren_depth += 1
        index += 1
      when 41_u8
        paren_depth -= 1 if paren_depth > 0
        index += 1
      when 91_u8
        bracket_depth += 1
        index += 1
      when 93_u8
        bracket_depth -= 1 if bracket_depth > 0
        index += 1
      when 123_u8
        brace_depth += 1
        index += 1
      when 125_u8
        brace_depth -= 1 if brace_depth > 0
        index += 1
      when 44_u8 # comma
        if paren_depth == 0 && bracket_depth == 0 && brace_depth == 0
          argument = text.byte_slice(start, index - start).strip
          arguments << argument unless argument.empty?
          start = index + 1
        end
        index += 1
      else
        index += 1
      end
    end

    argument = text.byte_slice(start, text.bytesize - start).strip
    arguments << argument unless argument.empty?
    arguments
  end

  # Returns the wrapped expression when `source` is exactly
  # `Mochi.raw(expression)`. A larger expression that merely contains
  # `Mochi.raw(...)` is rejected during validation instead of silently losing
  # its trust marker.
  def self.trusted_markup_source(source : String) : String?
    stripped = source.strip
    return nil unless stripped.starts_with?(TRUSTED_MARKUP_PREFIX)
    open = TRUSTED_MARKUP_PREFIX.bytesize - 1
    close = matching_delimiter(stripped, open, 40, 41)
    return nil unless close
    return nil unless close == stripped.bytesize - 1

    inner = stripped.byte_slice(open + 1, close - open - 1).strip
    inner.empty? ? nil : inner
  end

  def self.matching_brace(text : String, open : Int32) : Int32?
    matching_delimiter(text, open, 123, 125)
  end

  # Escape only Ruby placeholders at the HTML parser boundary. Lexbor decodes
  # these entities once, restoring exact Ruby before expression validation.
  def html_safe(template : String) : String
    String.build do |io|
      cursor = 0
      scan(template, "template", validate: false).each do |expression|
        io << template.byte_slice(cursor, expression.template_start - cursor)
        io << expression.full_text(template).gsub('&', "&amp;").gsub('"', "&quot;")
          .gsub('\'', "&#39;").gsub('<', "&lt;").gsub('>', "&gt;")
        cursor = expression.template_end
      end
      io << template.byte_slice(cursor)
    end
  end

  def self.escape_literal_braces(text : String) : String
    String.build do |io|
      i = 0
      while i < text.bytesize
        pair = text.byte_slice(i, Math.min(2, text.bytesize - i))
        if pair == "{{" || pair == "}}"
          io << (pair == "{{" ? '\u{E000}' : '\u{E001}')
          i += 2
        elsif text.byte_at(i) == 123_u8 && (close = matching_brace(text, i))
          io << text.byte_slice(i, close - i + 1)
          i = close + 1
        else
          io.write_byte(text.byte_at(i))
          i += 1
        end
      end
    end
  end

  # Structural scanners use character positions; skip a whole Ruby token so
  # strings containing {if ...} or {end} cannot become structural directives.
  def self.after_placeholder(text : String, char_pos : Int32) : Int32
    open = char_to_byte(text, char_pos)
    close = matching_brace(text, open)
    close ? byte_to_char(text, close) + 1 : char_pos + 1
  end

  # Crystal regex and String#index report character offsets while the
  # tokenizer scans UTF-8 bytes. These helpers cross that boundary once at
  # each entry point instead of mixing the two units.
  def self.char_to_byte(text : String, char_index : Int32) : Int32
    return 0 if char_index <= 0
    return text.bytesize if char_index >= text.size
    text[0...char_index].bytesize
  end

  def self.byte_to_char(text : String, byte_index : Int32) : Int32
    return 0 if byte_index <= 0
    return text.size if byte_index >= text.bytesize
    text.byte_slice(0, byte_index).size
  end

  def self.matching_delimiter(text : String, open : Int32, open_byte : UInt8, close_byte : UInt8) : Int32?
    return nil unless open < text.bytesize && text.byte_at(open) == open_byte

    depth = 1
    index = open + 1
    while index < text.bytesize
      byte = text.byte_at(index)
      case byte
      when 39_u8, 34_u8, 96_u8
        index = skip_quoted(text, index)
      when 37_u8
        if close = percent_literal_end(text, index)
          index = close
        else
          index += 1
        end
      when 35_u8 # comment to end of line
        newline = text.byte_index("\n", index)
        index = newline ? newline : text.bytesize
      when open_byte
        depth += 1
        index += 1
      when close_byte
        depth -= 1
        return index if depth == 0
        index += 1
      else
        index += 1
      end
    end

    nil
  end

  private def validate_node(node : TreeSitter::Node, expression : TemplateExpression) : Nil
    if REJECTED_NODE_TYPES.includes?(node.type)
      raise TemplateExpressionError.new(
        "unsupported #{node.type.gsub("_", " ")} in template expression #{expression.source.inspect}; move it into a helper method",
        expression.span
      )
    end
    if node.type == "call"
      receiver = node.child_by_field_name("receiver")
      method = node.child_by_field_name("method")
      if receiver && method && receiver.text == "Mochi" && method.text == "raw" &&
         TemplateExpressionParser.trusted_markup_source(expression.source).nil?
        raise TemplateExpressionError.new(
          "Mochi.raw must wrap the entire template expression, got #{expression.source.inspect}",
          expression.span
        )
      end
    end
    node.each_named_child { |child| validate_node(child, expression) }
  end

  def self.whitespace?(byte : UInt8) : Bool
    byte == 32_u8 || byte == 9_u8 || byte == 10_u8 || byte == 13_u8
  end

  def self.skip_quoted(text : String, open : Int32) : Int32
    quote = text.byte_at(open)
    index = open + 1
    escaped = false
    while index < text.bytesize
      byte = text.byte_at(index)
      if escaped
        escaped = false
      elsif byte == 92_u8
        escaped = true
      elsif quote != 39_u8 && byte == 35_u8 && index + 1 < text.bytesize && text.byte_at(index + 1) == 123_u8
        close = matching_brace(text, index + 1)
        return text.bytesize unless close
        index = close
      elsif byte == quote
        return index + 1
      end
      index += 1
    end
    text.bytesize
  end

  def self.percent_literal_end(text : String, index : Int32) : Int32?
    return nil unless text.byte_at(index) == 37_u8
    kind_index = index + 1
    return nil unless kind_index < text.bytesize

    kind = text.byte_at(kind_index)
    return nil unless "QqWwIiRrSsXx".to_slice.includes?(kind)

    delimiter_index = kind_index + 1
    return nil unless delimiter_index < text.bytesize
    delimiter = text.byte_at(delimiter_index)
    closing = case delimiter
              when 123_u8 then 125_u8
              when  91_u8 then 93_u8
              when  40_u8 then 41_u8
              when  60_u8 then 62_u8
              else             delimiter
              end

    cursor = delimiter_index + 1
    depth = 1
    interpolate = "QWIrxX".to_slice.includes?(kind)
    while cursor < text.bytesize
      byte = text.byte_at(cursor)
      if byte == 92_u8
        cursor += 2
        next
      elsif interpolate && byte == 35_u8 && cursor + 1 < text.bytesize && text.byte_at(cursor + 1) == 123_u8
        close = matching_brace(text, cursor + 1)
        return text.bytesize unless close
        cursor = close + 1
        next
      elsif byte == closing
        depth -= 1
        return cursor + 1 if depth == 0
      elsif delimiter != closing && byte == delimiter
        depth += 1
      end
      cursor += 1
    end
    text.bytesize
  end

  def find_unquoted(text : String, needle : Int32) : Int32?
    index = 0
    while index < text.bytesize
      byte = text.byte_at(index)
      case byte
      when 39_u8, 34_u8, 96_u8
        index = self.class.skip_quoted(text, index)
      when 37_u8
        if close = self.class.percent_literal_end(text, index)
          index = close
        else
          index += 1
        end
      else
        return index if byte == needle.to_u8
        index += 1
      end
    end
    nil
  end
end
