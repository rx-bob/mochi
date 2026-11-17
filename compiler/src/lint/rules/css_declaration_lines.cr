require "set"

require "../../tree-sitter/string_extractor"
require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Style rule for component CSS. Declarations and block braces stay on
  # separate lines so a component stylesheet remains easy to scan without
  # requiring a full CSS parser.
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
        counts, braces, indentation = declaration_layout(content)
        counts.each_with_index do |count, line|
          if count > 1
            issues << line_issue(
              unit, method.unit_path, content, content_start, line_starts, line,
              "line has #{count} CSS declarations; maximum is 1",
              "Put each CSS declaration and block brace on its own line.",
            )
          elsif count > 0 && braces[line]
            issues << line_issue(
              unit, method.unit_path, content, content_start, line_starts, line,
              "CSS declaration shares a line with a block brace",
              "Put each CSS declaration and block brace on its own line.",
            )
          end

          if indentation[line]
            issues << line_issue(
              unit, method.unit_path, content, content_start, line_starts, line,
              "closing brace indentation does not match its selector",
              "Align the closing brace with the selector that opened the block.",
            )
          end
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

    private def self.line_issue(
      unit : SourceUnit,
      path : String,
      content : String,
      content_start : Int32,
      starts : Array(Int32),
      line : Int32,
      message : String,
      suggestion : String,
    ) : SourceIssue
      line_start = content_start + starts[line]
      line_end = content_start + content_line_finish(content, starts, line)
      line_end = trim_line_ending(unit.source, line_start, line_end)
      range = unit.map.range(line_start, line_end)
      SourceIssue.new(
        path,
        unit.map,
        range.start_byte,
        range.end_byte,
        message,
        RULE,
        suggestion,
      )
    end

    # Counts declarations and block braces per line. The scan ignores comments,
    # strings, parenthesized values, brackets, and Ruby interpolation. A
    # declaration without a trailing semicolon is counted on its start line when
    # its block closes.
    private def self.declaration_layout(content : String) : Tuple(Array(Int32), Array(Bool), Array(Bool))
      starts = content_line_starts(content)
      counts = Array(Int32).new(starts.size, 0)
      braces = Array(Bool).new(starts.size, false)
      indentation = Array(Bool).new(starts.size, false)
      blocks = [] of Int32?
      block_indents = [] of String
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
          mark_pending(blocks, line)
          index, line = skip_interpolation(content, index + 2, line, counts.size)
          next
        end

        case byte
        when 34_u8, 39_u8
          quote = byte
          index += 1
        when 40_u8
          parens += 1
          mark_pending(blocks, line)
          index += 1
        when 41_u8
          parens -= 1 if parens > 0
          mark_pending(blocks, line)
          index += 1
        when 91_u8
          brackets += 1
          mark_pending(blocks, line)
          index += 1
        when 93_u8
          brackets -= 1 if brackets > 0
          mark_pending(blocks, line)
          index += 1
        when 123_u8
          if parens == 0 && brackets == 0
            braces[line] = true if line < braces.size
            selector_line = blocks.last? || line
            block_indents << line_indent(content, starts, selector_line)
            reset_pending(blocks)
            blocks << nil
          else
            mark_pending(blocks, line)
          end
          index += 1
        when 125_u8
          if parens == 0 && brackets == 0
            braces[line] = true if line < braces.size
            unless blocks.empty?
              if expected = block_indents.last?
                indentation[line] = true if line < indentation.size && line_indent(content, starts, line) != expected
              end
              if start_line = blocks.last
                counts[start_line] += 1 if start_line < counts.size
              end
              blocks.pop
              block_indents.pop
              reset_pending(blocks)
            end
          else
            mark_pending(blocks, line)
          end
          index += 1
        when 59_u8
          if parens == 0 && brackets == 0 && !blocks.empty?
            if start_line = blocks.last
              counts[start_line] += 1 if start_line < counts.size
              blocks[blocks.size - 1] = nil
            end
          end
          index += 1
        when 10_u8
          line += 1 if line + 1 < counts.size
          index += 1
        when 9_u8, 13_u8, 32_u8
          index += 1
        else
          mark_pending(blocks, line)
          index += 1
        end
      end

      {counts, braces, indentation}
    end

    private def self.line_indent(content : String, starts : Array(Int32), line : Int32) : String
      start = starts[line]
      finish = content_line_finish(content, starts, line)
      index = start
      while index < finish
        byte = content.byte_at(index)
        break unless byte == 9_u8 || byte == 32_u8
        index += 1
      end
      content.byte_slice(start, index - start)
    end

    private def self.mark_pending(blocks : Array(Int32?), line : Int32) : Nil
      return if blocks.empty?
      blocks[blocks.size - 1] = line if blocks.last.nil?
    end

    private def self.reset_pending(blocks : Array(Int32?)) : Nil
      blocks[blocks.size - 1] = nil unless blocks.empty?
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
