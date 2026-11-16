require "../html/template_expression"
require "./diagnostic"

module Lint
  struct SourcePosition
    getter line : Int32
    getter column : Int32

    def initialize(@line : Int32, @column : Int32)
    end
  end

  # One byte range in an original source file with one-based, end-exclusive
  # Unicode character positions. Byte offsets stay internal.
  struct SourceRange
    getter start_byte : Int32
    getter end_byte : Int32
    getter start_line : Int32
    getter start_column : Int32
    getter end_line : Int32
    getter end_column : Int32

    def initialize(
      @start_byte : Int32,
      @end_byte : Int32,
      @start_line : Int32,
      @start_column : Int32,
      @end_line : Int32,
      @end_column : Int32,
    )
    end

    def start : SourcePosition
      SourcePosition.new(@start_line, @start_column)
    end

    def finish : SourcePosition
      SourcePosition.new(@end_line, @end_column)
    end
  end

  # Cached line starts for one source string. Tree-sitter reports byte columns
  # in rows; public lint locations use Unicode character columns instead.
  class SourceMap
    getter path : String
    getter source : String
    getter line_starts : Array(Int32)

    def initialize(@source : String, @path : String = "")
      @line_starts = [0]
      index = 0
      while index < @source.bytesize
        @line_starts << index + 1 if @source.byte_at(index) == 10_u8
        index += 1
      end
    end

    def position(byte_offset : Int32) : SourcePosition
      offset = boundary(byte_offset)
      line_index = line_index_for(offset)
      line_start = @line_starts[line_index]
      column = @source.byte_slice(line_start, offset - line_start).size + 1
      SourcePosition.new(line_index + 1, column)
    end

    def range(start_byte : Int32, end_byte : Int32) : SourceRange
      start_offset = boundary(start_byte)
      end_offset = boundary(end_byte)
      end_offset = start_offset if end_offset < start_offset
      start_position = position(start_offset)
      end_position = position(end_offset)
      SourceRange.new(
        start_offset,
        end_offset,
        start_position.line,
        start_position.column,
        end_position.line,
        end_position.column,
      )
    end

    def line_start(line : Int32) : Int32
      index = (line - 1).clamp(0, @line_starts.size - 1)
      @line_starts[index]
    end

    def template_span(start_byte : Int32, end_byte : Int32) : TemplateSourceSpan
      value = range(start_byte, end_byte)
      length = @source.byte_slice(value.start_byte, value.end_byte - value.start_byte).size
      TemplateSourceSpan.new(
        @path,
        value.start_line,
        value.start_column,
        value.end_line,
        value.end_column,
        length,
      )
    end

    def diagnostic(
      start_byte : Int32,
      end_byte : Int32,
      severity : Severity,
      rule : String,
      message : String,
      suggestion : String? = nil,
    ) : Diagnostic
      value = range(start_byte, end_byte)
      Diagnostic.new(
        path: @path,
        start_line: value.start_line,
        start_column: value.start_column,
        end_line: value.end_line,
        end_column: value.end_column,
        start_byte: value.start_byte,
        end_byte: value.end_byte,
        severity: severity,
        rule: rule,
        message: message,
        suggestion: suggestion,
      )
    end

    private def line_index_for(offset : Int32) : Int32
      low = 0
      high = @line_starts.size
      while low + 1 < high
        middle = (low + high) // 2
        if @line_starts[middle] <= offset
          low = middle
        else
          high = middle
        end
      end
      low
    end

    private def boundary(byte_offset : Int32) : Int32
      offset = byte_offset.clamp(0, @source.bytesize)
      while offset > 0 && offset < @source.bytesize && (@source.byte_at(offset) & 0xC0_u8) == 0x80_u8
        offset -= 1
      end
      offset
    end
  end
end
