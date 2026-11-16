require "set"

require "../html/template_expression"

module Lint::TemplateElements
  record Attribute,
    name : String,
    start : Int32,
    finish : Int32,
    name_start : Int32,
    name_end : Int32,
    value_start : Int32,
    value_end : Int32,
    bare : Bool

  record TextSegment, start : Int32, finish : Int32

  class Element
    getter tag : String
    getter start : Int32
    getter name_start : Int32
    getter name_end : Int32
    getter finish : Int32
    getter attributes : Array(Attribute)
    getter dynamic_attributes : Bool
    getter children = [] of Element
    getter text_segments = [] of TextSegment
    property dynamic_content = false
    property parent : Element?
    property close_start : Int32?
    property end_byte : Int32?

    def initialize(
      @tag : String,
      @start : Int32,
      @name_start : Int32,
      @name_end : Int32,
      @finish : Int32,
      @attributes : Array(Attribute),
      @dynamic_attributes : Bool,
    )
      @parent = nil
      @close_start = nil
      @end_byte = nil
    end

    def attribute(name : String) : Attribute?
      @attributes.find { |candidate| candidate.name.downcase == name }
    end

    def dynamic_attributes? : Bool
      @dynamic_attributes
    end
  end

  record Document, roots : Array(Element), elements : Array(Element)

  VOID_ELEMENTS = Set{
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
  }

  def self.scan(text : String, parser : TemplateExpressionParser = TemplateExpressionParser.new) : Document
    Scanner.new(text, parser).scan
  end

  private class Scanner
    @roots = [] of Element
    @elements = [] of Element
    @stack = [] of Element
    @index = 0
    @text_start = -1

    def initialize(@text : String, @parser : TemplateExpressionParser)
    end

    def scan : Document
      while @index < @text.bytesize
        case @text.byte_at(@index)
        when 60_u8 # <
          scan_angle
        when 123_u8 # {
          scan_open_brace
        when 125_u8 # }
          scan_close_brace
        else
          start_text
          @index += 1
        end
      end

      flush_text(@text.bytesize)
      close_unclosed
      Document.new(@roots, @elements)
    end

    private def scan_angle : Nil
      flush_text(@index)

      if @text.byte_slice(@index, Math.min(4, @text.bytesize - @index)) == "<!--"
        ending = @text.byte_index("-->", @index)
        @index = ending ? ending + 3 : @text.bytesize
        return
      end

      if @index + 1 >= @text.bytesize
        start_text
        @index += 1
        return
      end

      case next_byte = @text.byte_at(@index + 1)
      when 47_u8 # /
        scan_end_tag
      when 33_u8, 63_u8 # ! ?
        @index = skip_tag(@index + 2)
      else
        if letter?(next_byte)
          scan_start_tag
        else
          start_text
          @index += 1
        end
      end
    end

    private def scan_open_brace : Nil
      if @index + 1 < @text.bytesize && @text.byte_at(@index + 1) == 123_u8
        start_text
        @index += 2
        return
      end

      flush_text(@index)
      close = TemplateExpressionParser.matching_brace(@text, @index)
      unless close
        @stack.last?.try &.dynamic_content = true
        @index += 1
        return
      end

      inner_start = @index + 1
      inner_end = close
      while inner_start < inner_end && whitespace?(@text.byte_at(inner_start))
        inner_start += 1
      end
      while inner_end > inner_start && whitespace?(@text.byte_at(inner_end - 1))
        inner_end -= 1
      end

      source = @text.byte_slice(inner_start, inner_end - inner_start)
      @stack.last?.try &.dynamic_content = true unless structural?(source)
      @index = close + 1
    end

    private def scan_close_brace : Nil
      if @index + 1 < @text.bytesize && @text.byte_at(@index + 1) == 125_u8
        start_text
        @index += 2
      else
        start_text
        @index += 1
      end
    end

    private def scan_start_tag : Nil
      start = @index
      index = start + 1
      name_start = index
      while index < @text.bytesize && name_byte?(@text.byte_at(index))
        index += 1
      end
      name_end = index
      tag = @text.byte_slice(name_start, name_end - name_start).downcase

      if tag.empty?
        start_text
        @index += 1
        return
      end

      attributes = [] of Attribute
      dynamic_attributes = false
      self_closing = false
      finish = @text.bytesize

      while index < @text.bytesize
        index = skip_whitespace(@text, index)
        break if index >= @text.bytesize

        byte = @text.byte_at(index)
        if byte == 62_u8 # >
          finish = index + 1
          index = finish
          break
        end
        if byte == 47_u8 && index + 1 < @text.bytesize && @text.byte_at(index + 1) == 62_u8
          self_closing = true
          finish = index + 2
          index = finish
          break
        end
        if byte == 123_u8 # {
          dynamic_attributes = true
          index = skip_placeholder(@text, index)
          next
        end
        unless name_byte?(byte)
          index += 1
          next
        end

        attribute_start = index
        while index < @text.bytesize && name_byte?(@text.byte_at(index))
          index += 1
        end
        attribute_name_end = index
        attribute_name = @text.byte_slice(attribute_start, attribute_name_end - attribute_start)
        index = skip_whitespace(@text, index)

        value_start = index
        value_end = index
        bare = true

        if index < @text.bytesize && @text.byte_at(index) == 61_u8 # =
          bare = false
          index += 1
          index = skip_whitespace(@text, index)
          if index < @text.bytesize && (text_byte = @text.byte_at(index)) && (text_byte == 34_u8 || text_byte == 39_u8)
            quote = text_byte
            index += 1
            value_start = index
            closed = false
            while index < @text.bytesize
              current = @text.byte_at(index)
              if current == quote
                value_end = index
                index += 1
                closed = true
                break
              elsif current == 123_u8
                if close = TemplateExpressionParser.matching_brace(@text, index)
                  dynamic_attributes = true if hash_spread?(index, close, quoted: true)
                  index = close + 1
                else
                  index += 1
                end
              else
                index += 1
              end
            end
            value_end = index unless closed
          else
            value_start = index
            while index < @text.bytesize
              current = @text.byte_at(index)
              break if whitespace?(current) || current == 62_u8
              break if current == 47_u8 && index + 1 < @text.bytesize && @text.byte_at(index + 1) == 62_u8
              if current == 123_u8
                if close = TemplateExpressionParser.matching_brace(@text, index)
                  dynamic_attributes = true if hash_spread?(index, close, quoted: false)
                  index = close + 1
                else
                  index += 1
                end
              else
                index += 1
              end
            end
            value_end = index
          end
        end

        attributes << Attribute.new(
          attribute_name,
          attribute_start,
          index,
          attribute_start,
          attribute_name_end,
          value_start,
          value_end,
          bare,
        )
      end

      element = Element.new(tag, start, name_start, name_end, finish, attributes, dynamic_attributes)
      if parent = @stack.last?
        element.parent = parent
        parent.children << element
      else
        @roots << element
      end
      @elements << element

      if self_closing || VOID_ELEMENTS.includes?(tag)
        element.close_start = finish
        element.end_byte = finish
      else
        @stack << element
      end
      @index = index
    end

    private def scan_end_tag : Nil
      start = @index
      index = start + 2
      index = skip_whitespace(@text, index)
      name_start = index
      while index < @text.bytesize && name_byte?(@text.byte_at(index))
        index += 1
      end
      name_end = index
      tag = @text.byte_slice(name_start, name_end - name_start).downcase

      close = @text.byte_index(">", index)
      next_index = close ? close + 1 : @text.bytesize
      close_element(tag, start, next_index) unless tag.empty?
      @index = next_index
    end

    private def close_element(tag : String, close_start : Int32, next_index : Int32) : Nil
      match = @stack.rindex { |element| element.tag == tag }
      return unless match

      while @stack.size > match
        element = @stack.pop
        element.close_start ||= close_start
        element.end_byte ||= next_index
      end
    end

    private def close_unclosed : Nil
      while element = @stack.pop?
        element.end_byte ||= @text.bytesize
      end
    end

    private def start_text : Nil
      @text_start = @index if @text_start < 0
    end

    private def flush_text(limit : Int32) : Nil
      return if @text_start < 0

      finish = limit
      if finish > @text_start
        if parent = @stack.last?
          parent.text_segments << TextSegment.new(@text_start, finish)
        end
      end
      @text_start = -1
    end

    private def hash_spread?(index : Int32, close : Int32, quoted : Bool) : Bool
      return false unless index + 1 < @text.bytesize && @text.byte_at(index + 1) == 123_u8
      return true unless quoted
      token = @text.byte_slice(index, close - index + 1)
      @parser.hash_literal_intent?(token[1...-1])
    end

    private def skip_placeholder(text : String, index : Int32) : Int32
      if close = TemplateExpressionParser.matching_brace(text, index)
        close + 1
      else
        index + 1
      end
    end

    private def skip_tag(index : Int32) : Int32
      while index < @text.bytesize
        return index + 1 if @text.byte_at(index) == 62_u8
        index += 1
      end
      index
    end

    private def skip_whitespace(text : String, index : Int32) : Int32
      while index < text.bytesize && whitespace?(text.byte_at(index))
        index += 1
      end
      index
    end

    private def structural?(source : String) : Bool
      value = source.strip
      return true if value == "else" || value == "end"
      ["each ", "if ", "elsif ", "unless ", "with "].any? { |prefix| value.starts_with?(prefix) }
    end

    private def letter?(byte : UInt8) : Bool
      (65_u8 <= byte <= 90_u8) || (97_u8 <= byte <= 122_u8)
    end

    private def name_byte?(byte : UInt8) : Bool
      letter?(byte) || (48_u8 <= byte <= 57_u8) ||
        byte == 95_u8 || byte == 45_u8 || byte == 58_u8 || byte == 46_u8
    end

    private def whitespace?(byte : UInt8) : Bool
      byte == 32_u8 || byte == 9_u8 || byte == 10_u8 || byte == 13_u8 || byte == 12_u8
    end
  end
end
