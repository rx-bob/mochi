require "./template_expression"

class EachResult
  property html : String
  property each_blocks : Array(EachBlock)

  def initialize(@html : String, @each_blocks : Array(EachBlock))
  end

  def to_s(io : IO)
    io << "EachResult(html: #{html}, each_blocks: #{each_blocks})"
  end
end

class EachMatch
  property loop_def : EachLoopDef
  property content_start : Int32

  def initialize(@loop_def : EachLoopDef, @content_start : Int32)
  end
end

class EachBlock
  property loop_def : EachLoopDef
  property content : String
  property start_pos : Int32
  property end_pos : Int32
  property content_start_pos : Int32
  property id : Int32
  # Nested blocks extracted from this block's content, ordered by source
  # position. Linking happens once at extraction time so callers do not need
  # to compare positions from unrelated HTML fragments.
  property children : Array(EachBlock)

  def initialize(@loop_def : EachLoopDef, @content : String, @start_pos : Int32, @end_pos : Int32, @content_start_pos : Int32, @id : Int32 = 0)
    @children = [] of EachBlock
  end

  def contains?(other : EachBlock) : Bool
    other.start_pos > start_pos && other.end_pos < end_pos
  end

  def to_s(io : IO)
    io << "EachBlock(loop_def: #{loop_def}, content: #{@content}, start_pos: #{start_pos}, end_pos: #{end_pos}, content_start_pos: #{content_start_pos}, id: #{id})"
  end
end

private struct EachStackFrame
  property loop_def : EachLoopDef
  property start_pos : Int32
  property content_start : Int32
  property id : Int32

  def initialize(@loop_def, @start_pos, @content_start, @id)
  end
end

class EachLoopDef
  property array_name : String
  property item_name : String
  property index_name : String?
  # Optional Ruby expression evaluated by the VM for every row. The value is
  # sent to the browser as a row identity token, never as source text.
  property key_expression : String?

  def initialize(
    @array_name : String,
    @item_name : String,
    @index_name : String?,
    @key_expression : String? = nil,
  )
  end
end

class EachProcessor
  EACH_TOKEN     = "{each "
  END_TOKEN      = "{end}"
  EACH_TOKEN_LEN = 6
  END_TOKEN_LEN  = 5

  def self.process(html : String, id_start : Int32 = 0) : EachResult
    return EachResult.new(html, [] of EachBlock) unless html.includes?("{each ")

    all_blocks = extract_each_blocks(html, id_start)
    processed_html = replace_blocks_with_elements(html, all_blocks)

    # TODO testing
    return EachResult.new(processed_html, all_blocks)
  end

  def self.replace_blocks_with_elements(html : String, all_blocks : Array(EachBlock)) : String
    return html if all_blocks.empty?

    top_level = all_blocks.reject do |block|
      all_blocks.any? { |other| other != block && other.contains?(block) }
    end

    result = html.dup
    top_level.sort_by! { |b| -b.start_pos }

    top_level.each do |block|
      element = generate_element(block, all_blocks)
      result = replace_range(result, block.start_pos, block.end_pos, element)
    end

    return result
  end

  def self.replace_range(str : String, start_pos : Int32, end_pos : Int32, replacement : String) : String
    return str[0...start_pos] + replacement + str[end_pos..-1]
  end

  def self.generate_element(block : EachBlock, all_blocks : Array(EachBlock)) : String
    "<!--each-anchor-#{block.id}-->"
  end

  private def self.process_nested_blocks(block : EachBlock, all_blocks : Array(EachBlock)) : String
    nested = all_blocks.select { |b| block.contains?(b) }
    return block.content if nested.empty?

    content = block.content
    nested.sort_by! { |b| -b.start_pos }

    nested.each do |nested_block|
      rel_start = nested_block.start_pos - block.content_start_pos
      rel_end = nested_block.end_pos - block.content_start_pos
      nested_element = generate_element(nested_block, all_blocks)
      content = replace_range(content, rel_start, rel_end, nested_element)
    end

    return content
  end

  def self.extract_each_blocks(html : String, id_start : Int32 = 0) : Array(EachBlock)
    result = [] of EachBlock
    return result unless html.includes?("{each ")

    stack = [] of EachStackFrame
    # `{end}` closes the most recently opened template block. Track non-each
    # control blocks as well, or an `{if}` inside a row will truncate the row
    # before its attributes can be lowered with the row's lexical scope.
    block_stack = [] of Bool
    next_id = id_start
    pos = 0

    while pos < html.size
      next_brace = html.index('{', pos)
      break unless next_brace
      pos = next_brace

      if match = try_match_each_token(html, pos)
        stack << EachStackFrame.new(match.loop_def, pos, match.content_start, next_id)
        block_stack << true
        next_id += 1
        pos = match.content_start
      elsif try_match_control_token(html, pos)
        block_stack << false
        pos += 1
      elsif try_match_end_token(html, pos)
        unless block_stack.empty?
          closes_each = block_stack.pop
          if closes_each && !stack.empty?
            frame = stack.pop
            result << EachBlock.new(
              loop_def: frame.loop_def,
              content: html[frame.content_start...pos],
              start_pos: frame.start_pos,
              end_pos: pos + END_TOKEN_LEN,
              content_start_pos: frame.content_start,
              id: frame.id
            )
          end
        end
        pos += END_TOKEN_LEN
      else
        pos += 1
      end
    end
    link_nested_blocks(result)
    return result
  end

  # Assigns each extracted block to its smallest containing block. Blocks are
  # extracted on their closing `{end}`, so the resulting root list follows
  # source order only after sorting.
  def self.link_nested_blocks(blocks : Array(EachBlock)) : Nil
    blocks.each do |block|
      block.children.clear
    end

    blocks.each do |block|
      parent = nil
      blocks.each do |candidate|
        next if candidate == block
        next unless candidate.contains?(block)
        if parent.nil? || candidate.start_pos > parent.start_pos
          parent = candidate
        end
      end
      if parent
        parent.children << block
      end
    end

    blocks.each do |block|
      block.children.sort_by!(&.start_pos)
    end
  end

  def self.roots(blocks : Array(EachBlock)) : Array(EachBlock)
    blocks.select do |block|
      blocks.none? { |candidate| candidate != block && candidate.contains?(block) }
    end.sort_by(&.start_pos)
  end

  def self.try_match_each_token(html : String, pos : Int32) : EachMatch?
    return nil unless html.index(EACH_TOKEN, pos) == pos

    open_byte = TemplateExpressionParser.char_to_byte(html, pos)
    close_byte = TemplateExpressionParser.matching_brace(html, open_byte)
    return nil unless close_byte
    close_brace = TemplateExpressionParser.byte_to_char(html, close_byte)

    loop_str = html[(pos + EACH_TOKEN_LEN)...close_brace].strip
    loop_def = extract_loop_definition(loop_str)
    if loop_def
      return EachMatch.new(loop_def, close_brace + 1)
    end
    return nil
  end

  def self.extract_loop_definition(loop_str : String) : EachLoopDef?
    parts = loop_str.split(" as ")
    return nil unless parts.size == 2

    array_name = parts[0].strip
    return nil if array_name.empty?

    declarations = TemplateExpressionParser.split_arguments(parts[1])
    return nil if declarations.empty?

    item_name = declarations.shift
    return nil if item_name.nil? || item_name.empty?

    index_name = nil
    key_expression = nil
    declarations.each do |declaration|
      if match = declaration.match(/\Akey\s*:\s*(.*)\z/m)
        expression = match[1].strip
        if expression.empty?
          raise TemplateExpressionError.new("each key: requires a Ruby expression")
        end
        if key_expression
          raise TemplateExpressionError.new("each accepts only one key: expression")
        end
        key_expression = expression
      else
        if index_name
          raise TemplateExpressionError.new(
            "each loop accepts one item name, one index name, and one key: expression"
          )
        end
        index_name = declaration
      end
    end

    EachLoopDef.new(array_name, item_name, index_name, key_expression)
  end

  def self.try_match_end_token(html : String, pos : Int32) : Bool
    html.index(END_TOKEN, pos) == pos
  end

  def self.try_match_control_token(html : String, pos : Int32) : Bool
    {"{if ", "{unless ", "{with "}.any? do |token|
      html.index(token, pos) == pos
    end
  end
end
