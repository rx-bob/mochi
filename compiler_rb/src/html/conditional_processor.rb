# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class ConditionalMatch < T::Struct
  const :condition, String
  const :content_start, Integer
end

class ConditionalBlock < T::Struct
  extend T::Sig

  const :condition, String
  const :content, String
  const :start_pos, Integer
  const :end_pos, Integer
  const :content_start_pos, Integer
  const :id, Integer

  sig { params(other: ConditionalBlock).returns(T::Boolean) }
  def contains?(other)
    other.start_pos > start_pos && other.end_pos < end_pos
  end
end

class ConditionalResult < T::Struct
  const :html, String
  const :conditionals, T::Array[ConditionalBlock]
end

class StackFrame < T::Struct
  const :condition, String
  const :start_pos, Integer
  const :content_start, Integer
  const :id, Integer
end

class ConditionalProcessor
  extend T::Sig

  IF_TOKEN      = "{if "
  END_TOKEN     = "{end}"
  IF_TOKEN_LEN  = 4
  END_TOKEN_LEN = 5

  sig { params(html: String).returns(ConditionalResult) }
  def self.process(html)
    blocks = extract_conditionals(html)
    processed_html = replace_blocks_with_elements(html, blocks)
    ConditionalResult.new(html: processed_html, conditionals: blocks)
  end

  sig { params(html: String).returns(T::Array[ConditionalBlock]) }
  def self.extract_conditionals(html)
    blocks = T.let([], T::Array[ConditionalBlock])
    stack = T.let([], T::Array[StackFrame])
    next_id = T.let(0, Integer)
    pos = T.let(0, Integer)

    while pos < html.size
      if match = try_match_if_token(html, pos)
        stack << StackFrame.new(
          condition: match.condition,
          start_pos: pos,
          content_start: match.content_start,
          id: next_id
        )
        next_id += 1
        pos = match.content_start
      elsif try_match_end_token(html, pos)
        unless stack.empty?
          blocks << build_block_from_frame(T.must(stack.pop), html, pos)
        end
        pos += END_TOKEN_LEN
      else
        pos += 1
      end
    end

    blocks
  end

  sig { params(html: String, pos: Integer).returns(T.nilable(ConditionalMatch)) }
  def self.try_match_if_token(html, pos)
    substr = html[pos..]
    return nil unless substr && substr.start_with?(IF_TOKEN)

    close_brace = html.index("}", pos)
    return nil unless close_brace

    ConditionalMatch.new(
      condition: T.must(html[(pos + IF_TOKEN_LEN)...close_brace]).strip,
      content_start: close_brace + 1,
    )
  end

  sig { params(html: String, pos: Integer).returns(T::Boolean) }
  def self.try_match_end_token(html, pos)
    substr = html[pos..]
    !!(substr && substr.start_with?(END_TOKEN))
  end
  private_class_method :try_match_end_token

  sig do
    params(
      frame: StackFrame,
      html: String,
      end_pos: Integer
    ).returns(ConditionalBlock)
  end
  def self.build_block_from_frame(frame, html, end_pos)
    ConditionalBlock.new(
      condition: frame.condition,
      content: T.must(html[frame.content_start...end_pos]),
      start_pos: frame.start_pos,
      end_pos: end_pos + END_TOKEN_LEN,
      content_start_pos: frame.content_start,
      id: frame.id
    )
  end
  private_class_method :build_block_from_frame

  sig do
    params(
      html: String,
      blocks: T::Array[ConditionalBlock]
    ).returns(String)
  end
  def self.replace_blocks_with_elements(html, blocks)
    return html if blocks.empty?

    top_level_blocks = blocks.reject do |block|
      blocks.any? { |other| other != block && other.contains?(block) }
    end

    top_level_blocks.sort_by! { |b| -b.start_pos }

    result = T.let(html.dup, String)
    top_level_blocks.each do |block|
      element = generate_element(block, blocks)
      result = T.must(result[0...block.start_pos]) + element + T.must(result[block.end_pos..])
    end

    result
  end
  private_class_method :replace_blocks_with_elements

  sig do
    params(
      block: ConditionalBlock,
      all_blocks: T::Array[ConditionalBlock]
    ).returns(String)
  end
  def self.generate_element(block, all_blocks)
    "<!--if-anchor-#{block.id}-->"
  end
  private_class_method :generate_element

  # NOTE: dead code in Crystal source — not called from anywhere.
  # Ported faithfully for completeness.
  sig do
    params(
      block: ConditionalBlock,
      all_blocks: T::Array[ConditionalBlock]
    ).returns(String)
  end
  def self.process_nested_blocks(block, all_blocks)
    nested = find_nested_blocks(block, all_blocks)
    return block.content if nested.empty?

    content = block.content
    nested.sort_by! { |b| -b.start_pos }

    nested.each do |nested_block|
      rel_start = nested_block.start_pos - block.content_start_pos
      rel_end = nested_block.end_pos - block.content_start_pos
      nested_element = generate_element(nested_block, all_blocks)
      content = replace_range(content, rel_start, rel_end, nested_element)
    end

    content
  end
  private_class_method :process_nested_blocks

  # NOTE: dead code in Crystal source — not called from anywhere.
  # Ported faithfully for completeness.
  sig do
    params(
      block: ConditionalBlock,
      all_blocks: T::Array[ConditionalBlock]
    ).returns(T::Array[ConditionalBlock])
  end
  def self.find_nested_blocks(block, all_blocks)
    all_blocks.select { |b| block.contains?(b) }
  end
  private_class_method :find_nested_blocks

  sig do
    params(
      str: String,
      start_pos: Integer,
      end_pos: Integer,
      replacement: String
    ).returns(String)
  end
  def self.replace_range(str, start_pos, end_pos, replacement)
    T.must(str[0...start_pos]) + replacement + T.must(str[end_pos..])
  end
  private_class_method :replace_range
end
