class ConditionalResult
  property html : String
  property conditionals : Array(ConditionalBlock)

  def initialize(@html : String, @conditionals : Array(ConditionalBlock))
  end
end

class ConditionalMatch
  property condition : String
  property content_start : Int32

  def initialize(@condition : String, @content_start : Int32)
  end
end

# One branch of an `{if}` / `{elsif}` / `{else}` chain. An else branch has a
# nil condition. `children` holds conditionals nested directly in this branch;
# deeper conditionals live on those children's own branches.
class ConditionalBranch
  property condition : String?
  property content : String
  property start_pos : Int32
  property end_pos : Int32
  property children : Array(ConditionalBlock)

  def initialize(
    @condition : String?,
    @content : String,
    @start_pos : Int32,
    @end_pos : Int32,
    @children : Array(ConditionalBlock) = [] of ConditionalBlock,
  )
  end
end

class ConditionalBlock
  property branches : Array(ConditionalBranch)
  property start_pos : Int32
  property end_pos : Int32
  property content_start_pos : Int32
  property id : Int32

  def initialize(
    @branches : Array(ConditionalBranch),
    @start_pos : Int32,
    @end_pos : Int32,
    @content_start_pos : Int32,
    @id : Int32 = 0,
  )
  end

  # Backwards-compatible constructor for a single `{if}` branch.
  def initialize(
    condition : String,
    content : String,
    start_pos : Int32,
    end_pos : Int32,
    content_start_pos : Int32,
    id : Int32 = 0,
  )
    @branches = [ConditionalBranch.new(condition, content, content_start_pos, end_pos)]
    @start_pos = start_pos
    @end_pos = end_pos
    @content_start_pos = content_start_pos
    @id = id
  end

  def condition : String
    branches.first?.try(&.condition) || ""
  end

  def content : String
    branches.first?.try(&.content) || ""
  end

  # Check if another block is nested within this block.
  def contains?(other : ConditionalBlock) : Bool
    other.start_pos > start_pos && other.end_pos < end_pos
  end

  def to_s(io : IO)
    io << "ConditionalBlock(branches: #{@branches.size}, start_pos: #{start_pos}, end_pos: #{end_pos}, content_start_pos: #{content_start_pos}, id: #{id})"
  end
end

private class StackFrame
  property condition : String?
  property start_pos : Int32
  property content_start : Int32
  property id : Int32
  property branches : Array(ConditionalBranch)
  property children : Array(ConditionalBlock)

  def initialize(@condition, @start_pos, @content_start, @id)
    @branches = [] of ConditionalBranch
    @children = [] of ConditionalBlock
  end
end

class ConditionalProcessor
  IF_TOKEN        = "{if "
  ELSIF_TOKEN     = "{elsif "
  ELSE_TOKEN      = "{else}"
  EACH_TOKEN      = "{each "
  UNLESS_TOKEN    = "{unless "
  END_TOKEN       = "{end}"
  IF_TOKEN_LEN    = IF_TOKEN.size
  ELSIF_TOKEN_LEN = ELSIF_TOKEN.size
  ELSE_TOKEN_LEN  = ELSE_TOKEN.size
  END_TOKEN_LEN   = END_TOKEN.size

  # Main entry point. Processes HTML with `{if}` / `{elsif}` / `{else}` /
  # `{end}` chains and replaces each top-level chain with a comment anchor.
  def self.process(html : String) : ConditionalResult
    blocks = extract_conditionals(html)
    processed_html = replace_blocks_with_elements(html, blocks)
    ConditionalResult.new(processed_html, blocks)
  end

  # Extract every conditional block, including nested blocks. A chain is one
  # block with multiple branches. Nested blocks are linked through their
  # containing branch so callers can recursively compile branch templates.
  def self.extract_conditionals(html : String) : Array(ConditionalBlock)
    blocks = [] of ConditionalBlock
    stack = [] of StackFrame
    next_id = 0
    pos = 0

    while pos < html.size
      if match = try_match_if_token(html, pos)
        stack << StackFrame.new(match.condition, pos, match.content_start, next_id)
        next_id += 1
        pos = match.content_start
      elsif match = try_match_elsif_token(html, pos)
        unless stack.empty?
          frame = stack.last
          finish_branch(frame, html, pos)
          frame.condition = match.condition
          frame.content_start = match.content_start
          frame.children = [] of ConditionalBlock
        end
        pos = match.content_start
      elsif try_match_else_token(html, pos)
        unless stack.empty?
          frame = stack.last
          finish_branch(frame, html, pos)
          frame.condition = nil
          frame.content_start = pos + ELSE_TOKEN_LEN
          frame.children = [] of ConditionalBlock
        end
        pos += ELSE_TOKEN_LEN
      elsif try_match_end_token(html, pos)
        unless stack.empty?
          frame = stack.pop
          finish_branch(frame, html, pos)
          first_branch = frame.branches.first
          block = ConditionalBlock.new(
            frame.branches,
            frame.start_pos,
            pos + END_TOKEN_LEN,
            first_branch.try(&.start_pos) || frame.content_start,
            frame.id
          )
          blocks << block
          stack.last.children << block unless stack.empty?
        end
        pos += END_TOKEN_LEN
      elsif each_start = try_match_each_token(html, pos)
        # Each blocks carry their own `{end}`. Skip them so a `{each}` inside
        # an `{if}` branch cannot close the conditional early. EachProcessor
        # handles the block when the surrounding branch is compiled.
        pos = skip_each_block(html, each_start)
      else
        pos += 1
      end
    end

    blocks
  end

  def self.try_match_if_token(html : String, pos : Int32) : ConditionalMatch?
    match_token(html, pos, IF_TOKEN, IF_TOKEN_LEN)
  end

  def self.try_match_elsif_token(html : String, pos : Int32) : ConditionalMatch?
    match_token(html, pos, ELSIF_TOKEN, ELSIF_TOKEN_LEN)
  end

  private def self.match_token(html : String, pos : Int32, token : String, token_len : Int32) : ConditionalMatch?
    return nil unless html[pos..].starts_with?(token)

    close_brace = html.index("}", pos)
    return nil unless close_brace

    ConditionalMatch.new(
      html[(pos + token_len)...close_brace].strip,
      close_brace + 1,
    )
  end

  private def self.try_match_else_token(html : String, pos : Int32) : Bool
    html[pos..].starts_with?(ELSE_TOKEN)
  end

  private def self.try_match_end_token(html : String, pos : Int32) : Bool
    html[pos..].starts_with?(END_TOKEN)
  end

  private def self.try_match_each_token(html : String, pos : Int32) : Int32?
    return nil unless html[pos..].starts_with?(EACH_TOKEN)

    close_brace = html.index("}", pos)
    return nil unless close_brace

    close_brace + 1
  end

  private def self.skip_each_block(html : String, content_start : Int32) : Int32
    depth = 1
    pos = content_start

    while pos < html.size
      if block_open_at?(html, pos)
        depth += 1
        pos += 1
      elsif try_match_end_token(html, pos)
        depth -= 1
        return pos + END_TOKEN_LEN if depth == 0
        pos += END_TOKEN_LEN
      else
        pos += 1
      end
    end

    html.size
  end

  private def self.block_open_at?(html : String, pos : Int32) : Bool
    html[pos..].starts_with?(IF_TOKEN) ||
      html[pos..].starts_with?(UNLESS_TOKEN) ||
      html[pos..].starts_with?(EACH_TOKEN)
  end

  private def self.finish_branch(frame : StackFrame, html : String, content_end : Int32)
    frame.branches << ConditionalBranch.new(
      frame.condition,
      html[frame.content_start...content_end],
      frame.content_start,
      content_end,
      frame.children
    )
  end

  # Replace top-level chains with comment anchors. Nested chains remain in
  # their branch content and are anchored when that branch is compiled.
  private def self.replace_blocks_with_elements(html : String, blocks : Array(ConditionalBlock)) : String
    return html if blocks.empty?

    top_level_blocks = blocks.reject do |block|
      blocks.any? { |other| other != block && other.contains?(block) }
    end

    top_level_blocks.sort_by! { |block| -block.start_pos }

    result = html.dup
    top_level_blocks.each do |block|
      result = result[0...block.start_pos] + generate_element(block) + result[block.end_pos..-1]
    end

    result
  end

  private def self.generate_element(block : ConditionalBlock) : String
    "<!--if-anchor-#{block.id}-->"
  end
end
