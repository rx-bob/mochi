# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class EachLoopDef < T::Struct
  const :array_name, String
  const :item_name, String
  const :index_name, T.nilable(String)
end

class EachBlock < T::Struct
  extend T::Sig

  const :loop_def, EachLoopDef
  const :content, String
  const :start_pos, Integer
  const :end_pos, Integer
  const :content_start_pos, Integer
  const :id, Integer

  sig { params(other: EachBlock).returns(T::Boolean) }
  def contains?(other)
    other.start_pos > start_pos && other.end_pos < end_pos
  end
end

class EachMatch < T::Struct
  const :loop_def, EachLoopDef
  const :content_start, Integer
end

class EachResult < T::Struct
  const :html, String
  const :each_blocks, T::Array[EachBlock]
end

class EachProcessor
  extend T::Sig

  EACH_TOKEN = "{each "
  END_TOKEN = "{end}"
  EACH_TOKEN_LEN = 6
  END_TOKEN_LEN = 5

  sig { params(html: String).returns(EachResult) }
  def self.process(html)
    all_blocks = extract_each_blocks(html)
    processed_html = replace_blocks_with_elements(html, all_blocks)
    EachResult.new(html: processed_html, each_blocks: all_blocks)
  end

  sig { params(html: String, all_blocks: T::Array[EachBlock]).returns(String) }
  def self.replace_blocks_with_elements(html, all_blocks)
    return html if all_blocks.empty?

    top_level = all_blocks.reject do |block|
      all_blocks.any? { |other| other != block && other.contains?(block) }
    end

    result = +html
    top_level.sort_by { |b| -b.start_pos }.each do |block|
      element = generate_element(block, all_blocks)
      result = replace_range(result, block.start_pos, block.end_pos, element)
    end

    result
  end

  sig { params(str: String, start_pos: Integer, end_pos: Integer, replacement: String).returns(String) }
  def self.replace_range(str, start_pos, end_pos, replacement)
    prefix = str[0...start_pos]
    suffix = str[end_pos..]
    T.must(prefix) + replacement + suffix.to_s
  end

  sig { params(block: EachBlock, all_blocks: T::Array[EachBlock]).returns(String) }
  def self.generate_element(block, all_blocks)
    "<!--each-anchor-#{block.id}-->"
  end

  sig { params(block: EachBlock, all_blocks: T::Array[EachBlock]).returns(String) }
  private_class_method def self.process_nested_blocks(block, all_blocks)
    nested = all_blocks.select { |b| block.contains?(b) }
    return block.content if nested.empty?

    content = block.content
    nested.sort_by { |b| -b.start_pos }.each do |nested_block|
      rel_start = nested_block.start_pos - block.content_start_pos
      rel_end = nested_block.end_pos - block.content_start_pos
      nested_element = generate_element(nested_block, all_blocks)
      content = replace_range(content, rel_start, rel_end, nested_element)
    end

    content
  end

  sig { params(html: String).returns(T::Array[EachBlock]) }
  def self.extract_each_blocks(html)
    result = T::Array[EachBlock].new
    stack = T::Array[EachStackFrame].new
    next_id = 0
    pos = 0

    while pos < html.size
      if match = try_match_each_token(html, pos)
        stack << EachStackFrame.new(loop_def: match.loop_def, start_pos: pos, content_start: match.content_start, id: next_id)
        next_id += 1
        pos = match.content_start
      elsif try_match_end_token(html, pos)
        unless stack.empty?
          frame = T.must(stack.pop)
          result << EachBlock.new(
            loop_def: frame.loop_def,
            content: html[frame.content_start...pos].to_s,
            start_pos: frame.start_pos,
            end_pos: pos + END_TOKEN_LEN,
            content_start_pos: frame.content_start,
            id: frame.id
          )
        end
        pos += END_TOKEN_LEN
      else
        pos += 1
      end
    end

    result
  end

  sig { params(html: String, pos: Integer).returns(T.nilable(EachMatch)) }
  def self.try_match_each_token(html, pos)
    substr = html[pos..]
    return nil unless substr && substr.start_with?(EACH_TOKEN)

    close_brace = html.index("}", pos)
    return nil unless close_brace

    loop_str = html[(pos + EACH_TOKEN_LEN)...close_brace].to_s.strip
    loop_def = extract_loop_definition(loop_str)
    return nil unless loop_def

    EachMatch.new(loop_def: loop_def, content_start: close_brace + 1)
  end

  sig { params(loop_str: String).returns(T.nilable(EachLoopDef)) }
  def self.extract_loop_definition(loop_str)
    parts = loop_str.split(" as ")
    return nil unless parts.size == 2

    if T.must(parts[1]).include?(",")
      item_parts = T.must(parts[1]).split(",")
      EachLoopDef.new(array_name: T.must(parts[0]), item_name: T.must(item_parts[0]).strip, index_name: T.must(item_parts[1]).strip)
    else
      EachLoopDef.new(array_name: T.must(parts[0]), item_name: T.must(parts[1]).strip, index_name: nil)
    end
  end

  sig { params(html: String, pos: Integer).returns(T::Boolean) }
  def self.try_match_end_token(html, pos)
    substr = html[pos..]
    !!(substr && substr.start_with?(END_TOKEN))
  end

  private_class_method :try_match_end_token
end

private

class EachStackFrame < T::Struct
  const :loop_def, EachLoopDef
  const :start_pos, Integer
  const :content_start, Integer
  const :id, Integer
end
