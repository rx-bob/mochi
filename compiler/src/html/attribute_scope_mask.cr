require "./each_processor"

# Shields each blocks from component-level attribute lowering. Row-scoped
# attribute helpers are lowered later by EachRowCompiler with their lexical
# item and index names available.
class AttributeScopeMask
  START = "\u{E100}"
  END   = "\u{E101}"

  def self.protect(html : String) : Tuple(String, Array(String))
    roots = EachProcessor.roots(EachProcessor.extract_each_blocks(html))
    return {html, [] of String} if roots.empty?

    result = html.dup
    saved = [] of String
    roots.sort_by { |block| -block.start_pos }.each do |block|
      index = saved.size
      saved << html[block.start_pos...block.end_pos]
      result = EachProcessor.replace_range(result, block.start_pos, block.end_pos, "#{START}#{index}#{END}")
    end
    {result, saved}
  end

  def self.restore(html : String, saved : Array(String)) : String
    result = html
    saved.each_with_index do |block, index|
      result = result.gsub("#{START}#{index}#{END}", block)
    end
    result
  end
end
