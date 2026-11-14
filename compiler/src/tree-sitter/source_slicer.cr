module TreeSitter
  class SourceSlicer
    # Removes disjoint source ranges. Tree-sitter byte ranges are used so an
    # `end` inside a heredoc or string can never terminate the wrong range.
    def self.remove_ranges(source : String, ranges : Array(Tuple(Int32, Int32))) : String
      return source if ranges.empty?

      builder = String::Builder.new
      cursor = 0
      ranges.sort_by! { |range| range[0] }
      ranges.each do |(start_byte, end_byte)|
        next if end_byte <= cursor

        builder << source.byte_slice(cursor, start_byte - cursor) if start_byte > cursor
        cursor = end_byte
      end
      builder << source.byte_slice(cursor, source.bytesize - cursor) if cursor < source.bytesize
      builder.to_s
    end
  end
end
