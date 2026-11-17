require "../../html/template_expression"
require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Rejects inline blocks whose opening expression and matching `end` share a
  # source line. Attribute-value blocks and HTML comments are skipped because
  # they are inline fragments rather than block markup.
  module TemplateBlockLines
    RULE    = "style/template-block-lines"
    OPENERS = Set{"if", "unless", "each", "with"}
    BLOCKS  = Set{"if", "unless", "each"}

    record Block, start : Int32, finish : Int32, kind : String, line : Int32

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
              line = view.map.position(view.source_byte(start)).line
              stack << Block.new(start, finish, kind, line)
            elsif source == "end"
              next if stack.empty?
              block = stack.pop
              next unless BLOCKS.includes?(block.kind)

              end_line = view.map.position(view.source_byte(start)).line
              next unless block.line == end_line

              range = view.source_range(block.start, block.finish)
              issues << SourceIssue.new(
                view.unit_path,
                view.map,
                range.start_byte,
                range.end_byte,
                "template block opens and closes on the same line",
                RULE,
                "Put the closing {end} on its own line.",
              )
            end
          else
            index += 1
          end
        end
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
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
  end
end
