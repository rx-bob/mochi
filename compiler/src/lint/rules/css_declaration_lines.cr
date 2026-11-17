require "set"

require "../../tree-sitter/string_extractor"
require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Style rule for component CSS. A line may carry one declaration; packed
  # declaration lists are reported so a component stylesheet stays readable
  # without requiring a full CSS parser.
  module CssDeclarationLines
    RULE = "style/css-declaration-lines"

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      issues = [] of SourceIssue
      seen = Set(Tuple(String, Int32)).new

      index.classes.values.sort_by(&.qualified_name).each do |owner|
        method = owner.method("css")
        next unless method && !method.singleton
        next unless index.selected.includes?(method.unit_path)

        unit = index.unit(method.unit_path)
        next unless unit

        info = TreeSitter::StringExtractor.template_content_info(method.node)
        next unless info
        content_start = info[0]
        content_end = info[1]
        key = {method.unit_path, content_start}
        next if seen.includes?(key)
        seen << key

        content = unit.source.byte_slice(content_start, content_end - content_start)
        line_starts = content_line_starts(content)
        counts = declaration_counts(content)
        counts.each_with_index do |count, line|
          next if count <= 1

          line_start = content_start + line_starts[line]
          line_end = content_start + content_line_finish(content, line_starts, line)
          line_end = trim_line_ending(unit.source, line_start, line_end)
          range = unit.map.range(line_start, line_end)
          issues << SourceIssue.new(
            method.unit_path,
            unit.map,
            range.start_byte,
            range.end_byte,
            "line has #{count} CSS declarations; maximum is 1",
            RULE,
            "Put each CSS declaration on its own line.",
          )
        end
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end

    private def self.content_line_starts(content : String) : Array(Int32)
      starts = [0]
      index = 0
      while index < content.bytesize
        starts << index + 1 if content.byte_at(index) == 10_u8
        index += 1
      end
      starts
    end

    private def self.content_line_finish(content : String, starts : Array(Int32), line : Int32) : Int32
      line + 1 < starts.size ? starts[line + 1] : content.bytesize
    end

    private def self.trim_line_ending(source : String, start : Int32, finish : Int32) : Int32
      finish -= 1 if finish > start && source.byte_at(finish - 1) == 10_u8
      finish -= 1 if finish > start && source.byte_at(finish - 1) == 13_u8
      finish
    end

    # Counts declaration terminators per line. The scan ignores comments,
    # strings, parenthesized values, brackets, and Ruby interpolation. A
    # declaration without a trailing semicolon is counted when its block closes.
    private def self.declaration_counts(content : String) : Array(Int32)
      counts = Array(Int32).new(content_line_starts(content).size, 0)
      blocks = [] of Bool
      line = 0
      index = 0
      quote = nil
      in_comment = false
      parens = 0
      brackets = 0

      while index < content.bytesize
        byte = content.byte_at(index)

        if in_comment
          if byte == 42_u8 && index + 1 < content.bytesize && content.byte_at(index + 1) == 47_u8
            in_comment = false
            index += 2
          else
            line += 1 if byte == 10_u8 && line + 1 < counts.size
            index += 1
          end
          next
        end

        if quote
          if byte == 92_u8
            if index + 1 < content.bytesize
              line += 1 if content.byte_at(index + 1) == 10_u8 && line + 1 < counts.size
              index += 2
            else
              index += 1
            end
          elsif byte == quote
            quote = nil
            index += 1
          else
            line += 1 if byte == 10_u8 && line + 1 < counts.size
            index += 1
          end
          next
        end

        if byte == 47_u8 && index + 1 < content.bytesize && content.byte_at(index + 1) == 42_u8
          in_comment = true
          index += 2
          next
        end

        if byte == 35_u8 && index + 1 < content.bytesize && content.byte_at(index + 1) == 123_u8
          index, line = skip_interpolation(content, index + 2, line, counts.size)
          next
        end

        case byte
        when 34_u8, 39_u8
          quote = byte
          index += 1
        when 40_u8
          parens += 1
          mark_pending(blocks)
          index += 1
        when 41_u8
          parens -= 1 if parens > 0
          mark_pending(blocks)
          index += 1
        when 91_u8
          brackets += 1
          mark_pending(blocks)
          index += 1
        when 93_u8
          brackets -= 1 if brackets > 0
          mark_pending(blocks)
          index += 1
        when 123_u8
          if parens == 0 && brackets == 0
            mark_pending(blocks, false)
            blocks << false
          else
            mark_pending(blocks)
          end
          index += 1
        when 125_u8
          if parens == 0 && brackets == 0
            unless blocks.empty?
              counts[line] += 1 if blocks.last && line < counts.size
              blocks.pop
              mark_pending(blocks, false)
            end
          else
            mark_pending(blocks)
          end
          index += 1
        when 59_u8
          if parens == 0 && brackets == 0 && !blocks.empty?
            if blocks.last
              counts[line] += 1 if line < counts.size
              blocks[blocks.size - 1] = false
            end
          end
          index += 1
        when 10_u8
          line += 1 if line + 1 < counts.size
          index += 1
        when 9_u8, 13_u8, 32_u8
          index += 1
        else
          mark_pending(blocks)
          index += 1
        end
      end

      counts
    end

    private def self.mark_pending(blocks : Array(Bool), value = true) : Nil
      blocks[blocks.size - 1] = value unless blocks.empty?
    end

    private def self.skip_interpolation(
      content : String,
      index : Int32,
      line : Int32,
      line_count : Int32,
    ) : Tuple(Int32, Int32)
      depth = 1
      quote = nil

      while index < content.bytesize && depth > 0
        byte = content.byte_at(index)

        if quote
          if byte == 92_u8
            if index + 1 < content.bytesize
              line += 1 if content.byte_at(index + 1) == 10_u8 && line + 1 < line_count
              index += 2
            else
              index += 1
            end
          elsif byte == quote
            quote = nil
            index += 1
          else
            line += 1 if byte == 10_u8 && line + 1 < line_count
            index += 1
          end
          next
        end

        case byte
        when 34_u8, 39_u8
          quote = byte
          index += 1
        when 35_u8
          if index + 1 < content.bytesize && content.byte_at(index + 1) == 123_u8
            depth += 1
            index += 2
          else
            index += 1
          end
        when 123_u8
          depth += 1
          index += 1
        when 125_u8
          depth -= 1
          index += 1
        when 10_u8
          line += 1 if line + 1 < line_count
          index += 1
        else
          index += 1
        end
      end

      {index, line}
    end
  end
end
