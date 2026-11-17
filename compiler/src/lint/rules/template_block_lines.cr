require "../../html/template_expression"
require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Rejects block markup that shares a source line with block content. Opening
  # expressions, branch markers, and the closing `end` must each be alone on
  # their line, and closing markers must align with the opening expression.
  # Attribute-value blocks and HTML comments are skipped because they are
  # inline fragments rather than block markup.
  module TemplateBlockLines
    RULE    = "style/template-block-lines"
    OPENERS = Set{"if", "unless", "each", "with"}
    BLOCKS  = Set{"if", "unless", "each"}

    MESSAGE           = "template block shares a line with block content"
    SUGGESTION        = "Put the opening expression, block body, and closing {end} on separate lines."
    INDENT_MESSAGE    = "template block marker indentation does not match its opening expression"
    INDENT_SUGGESTION = "Align the block marker with the opening expression."

    class Block
      getter start : Int32
      getter finish : Int32
      getter kind : String
      getter column : Int32
      property flagged = false

      def initialize(@start, @finish, @kind, @column)
      end
    end

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      issues = [] of SourceIssue
      index.target_templates.each do |view|
        attribute_ranges = view.attributes.map { |attribute| {attribute.value_start, attribute.value_end} }
        stack = [] of Block
        index = 0

        while index < view.text.bytesize
          byte = view.text.byte_at(index)
          case byte
          when 60_u8 # <
            if comment_start?(view.text, index)
              ending = view.text.byte_index("-->", index + 4)
              index = ending ? ending + 3 : view.text.bytesize
            else
              index += 1
            end
          when 123_u8 # {
            if index + 1 < view.text.bytesize && view.text.byte_at(index + 1) == 123_u8
              index += 2
              next
            end

            close = TemplateExpressionParser.matching_brace(view.text, index)
            unless close
              index += 1
              next
            end

            start = index
            finish = close + 1
            source = view.text.byte_slice(index + 1, close - index - 1).strip
            index = close + 1
            next if inside_attribute?(attribute_ranges, start)

            if kind = opener_kind(source)
              block = Block.new(start, finish, kind, column(view, start, finish))
              if BLOCKS.includes?(kind) && !alone_on_line?(view, start, finish)
                block.flagged = true
                issues << issue(view, start, finish)
              end
              stack << block
            elsif branch_marker?(source)
              block = stack.last?
              if block && BLOCKS.includes?(block.kind)
                if !alone_on_line?(view, start, finish)
                  issues << issue(view, start, finish)
                elsif column(view, start, finish) != block.column
                  issues << issue(view, start, finish, INDENT_MESSAGE, INDENT_SUGGESTION)
                end
              end
            elsif source == "end"
              next if stack.empty?
              block = stack.pop
              next unless BLOCKS.includes?(block.kind)
              next if block.flagged

              if !alone_on_line?(view, start, finish)
                issues << issue(view, start, finish)
              elsif column(view, start, finish) != block.column
                issues << issue(view, start, finish, INDENT_MESSAGE, INDENT_SUGGESTION)
              end
            end
          else
            index += 1
          end
        end
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end

    private def self.issue(
      view : TemplateView,
      start : Int32,
      finish : Int32,
      message : String = MESSAGE,
      suggestion : String = SUGGESTION,
    ) : SourceIssue
      range = view.source_range(start, finish)
      SourceIssue.new(
        view.unit_path,
        view.map,
        range.start_byte,
        range.end_byte,
        message,
        RULE,
        suggestion,
      )
    end

    private def self.column(view : TemplateView, start : Int32, finish : Int32) : Int32
      view.map.position(view.source_range(start, finish).start_byte).column
    end

    private def self.alone_on_line?(view : TemplateView, start : Int32, finish : Int32) : Bool
      range = view.source_range(start, finish)
      line = view.map.position(range.start_byte).line
      line_start = view.map.line_start(line)
      line_end = view.map.source.byte_index(10_u8, range.start_byte) || view.map.source.bytesize
      expression_end = range.end_byte.clamp(range.start_byte, line_end)
      prefix = view.map.source.byte_slice(line_start, range.start_byte - line_start)
      suffix = view.map.source.byte_slice(expression_end, line_end - expression_end)
      whitespace_only?(prefix) && whitespace_only?(suffix)
    end

    private def self.whitespace_only?(text : String) : Bool
      text.each_char.all? { |char| char == ' ' || char == '\t' || char == '\r' }
    end

    private def self.comment_start?(text : String, index : Int32) : Bool
      index + 4 <= text.bytesize && text.byte_slice(index, 4) == "<!--"
    end

    private def self.inside_attribute?(ranges : Array(Tuple(Int32, Int32)), offset : Int32) : Bool
      ranges.any? { |range| offset >= range[0] && offset < range[1] }
    end

    private def self.opener_kind(source : String) : String?
      OPENERS.each do |opener|
        return opener if source.starts_with?("#{opener} ")
      end
      nil
    end

    private def self.branch_marker?(source : String) : Bool
      source == "else" || source.starts_with?("elsif ")
    end
  end
end
