require "spec"

require "../../src/lint/source_map"

describe Lint::SourceMap do
  it "converts UTF-8 byte offsets to one-based Unicode character columns" do
    source = "aé←🚀b"
    map = Lint::SourceMap.new(source, "lib/Unicode.rb")

    map.position(0).should eq Lint::SourcePosition.new(1, 1)
    map.position(1).should eq Lint::SourcePosition.new(1, 2)
    map.position(3).should eq Lint::SourcePosition.new(1, 3)
    map.position(6).should eq Lint::SourcePosition.new(1, 4)
    map.position(10).should eq Lint::SourcePosition.new(1, 5)
    map.position(11).should eq Lint::SourcePosition.new(1, 6)
  end

  it "caches line starts for CRLF and reports end-exclusive ranges" do
    source = "x\r\né\r\nz"
    map = Lint::SourceMap.new(source, "lib/Crlf.rb")

    map.line_starts.should eq [0, 3, 7]
    map.line_start(2).should eq 3
    map.line_start(99).should eq 7

    range = map.range(3, 5)
    range.start_byte.should eq 3
    range.end_byte.should eq 5
    range.start_line.should eq 2
    range.start_column.should eq 1
    range.end_line.should eq 2
    range.end_column.should eq 2
  end

  it "handles an EOF offset and an offset inside a multibyte character" do
    source = "é"
    map = Lint::SourceMap.new(source, "lib/Edge.rb")

    map.position(source.bytesize).should eq Lint::SourcePosition.new(1, 2)
    map.position(1).should eq Lint::SourcePosition.new(1, 1)
    map.range(-20, 999).start_byte.should eq 0
    map.range(-20, 999).end_byte.should eq source.bytesize
  end

  it "builds diagnostics with Unicode character columns and original byte offsets" do
    source = "é{@name}"
    map = Lint::SourceMap.new(source, "lib/Template.rb")

    diagnostic = map.diagnostic(2, 8, Lint::Severity::Error, "templates/example", "message")

    diagnostic.path.should eq "lib/Template.rb"
    diagnostic.start_line.should eq 1
    diagnostic.start_column.should eq 2
    diagnostic.end_column.should eq 8
    diagnostic.start_byte.should eq 2
    diagnostic.end_byte.should eq 8
  end
end
