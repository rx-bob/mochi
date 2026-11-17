require "../../html/template_expression"
require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Requires line-leading child elements and template block markers to be
  # indented one level past their nearest containing element or block.
  module TemplateNestingIndent
    RULE    = "style/template-nesting-indent"
    OPENERS = Set{"if", "unless", "each", "with"}

    class Block
      getter start : Int32
      getter finish : Int32
      getter kind : String
      getter column : Int32
      property end_start : Int32?

      def initialize(@start, @finish, @kind, @column)
        @end_start = nil
      end
    end

    record Parent, column : Int32, span : Int32

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      issues = [] of SourceIssue
      index.target_templates.each do |view|
        blocks = scan_blocks(view)
        elements = view.elements.elements

        blocks.each do |block|
          next unless line_leading?(view, block.start)
          parent = nearest_parent(view, block.start, blocks, elements)
          next unless parent
          next if block.column >= parent.column + 2

          range = view.source_range(block.start, block.finish)
          issues << SourceIssue.new(
            view.unit_path,
            view.map,
            range.start_byte,
            range.end_byte,
            "template block marker is not indented relative to its parent",
            RULE,
            "Indent the block marker one level deeper than its parent.",
          )
        end

        elements.each do |element|
          next unless line_leading?(view, element.start)
          parent = element.parent
          next unless parent

          column = column(view, element.start, element.finish)
          parent_column = indent_column(view, parent.start)
          next if column >= parent_column + 2

          range = view.source_range(element.start, element.finish)
          issues << SourceIssue.new(
            view.unit_path,
            view.map,
            range.start_byte,
            range.end_byte,
            "child element is not indented relative to its parent element",
            RULE,
            "Indent <#{element.tag}> one level deeper than its parent.",
          )
        end
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end

    private def self.scan_blocks(view : TemplateView) : Array(Block)
      attribute_ranges = view.attributes.map { |attribute| {attribute.value_start, attribute.value_end} }
      blocks = [] of Block
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
            blocks << block
            stack << block
          elsif source == "end"
            if block = stack.pop?
              block.end_start = start
            end
          end
        else
          index += 1
        end
      end

      while block = stack.pop?
        block.end_start = view.text.bytesize
      end

      blocks
    end

    private def self.nearest_parent(
      view : TemplateView,
      offset : Int32,
      blocks : Array(Block),
      elements : Array(TemplateElements::Element),
    ) : Parent?
      candidates = [] of Parent

      if block = blocks
           .select { |candidate| block_contains?(candidate, offset) }
           .min_by? { |candidate| block_span(candidate) }
        candidates << Parent.new(indent_column(view, block.start), block_span(block))
      end

      if element = elements
           .select { |candidate| element_contains?(candidate, offset) }
           .min_by? { |candidate| element_span(candidate) }
        candidates << Parent.new(indent_column(view, element.start), element_span(element))
      end

      candidates.min_by?(&.span)
    end

    private def self.block_contains?(block : Block, offset : Int32) : Bool
      end_start = block.end_start
      return false unless end_start
      offset > block.finish && offset < end_start
    end

    private def self.block_span(block : Block) : Int32
      (block.end_start || block.finish) - block.finish
    end

    private def self.element_contains?(element : TemplateElements::Element, offset : Int32) : Bool
      body_start = element.finish
      body_end = element.close_start || element.end_byte || Int32::MAX
      offset > body_start && offset < body_end
    end

    private def self.element_span(element : TemplateElements::Element) : Int32
      body_start = element.finish
      body_end = element.close_start || element.end_byte || Int32::MAX
      body_end - body_start
    end

    private def self.line_leading?(view : TemplateView, offset : Int32) : Bool
      source_byte = view.source_byte(offset)
      line = view.map.position(source_byte).line
      line_start = view.map.line_start(line)
      prefix = view.map.source.byte_slice(line_start, source_byte - line_start)
      prefix.each_char.all? { |char| char == ' ' || char == '\t' }
    end

    private def self.column(view : TemplateView, start : Int32, finish : Int32) : Int32
      view.map.position(view.source_range(start, finish).start_byte).column
    end

    private def self.indent_column(view : TemplateView, offset : Int32) : Int32
      source_byte = view.source_byte(offset)
      line = view.map.position(source_byte).line
      line_start = view.map.line_start(line)
      prefix = view.map.source.byte_slice(line_start, source_byte - line_start)
      indent = 0
      prefix.each_char do |char|
        break unless char == ' ' || char == '\t'
        indent += 1
      end
      indent + 1
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
