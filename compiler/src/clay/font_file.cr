require "file/tempfile"
require "file_utils"

# Static OpenType faces use the same outlines and metrics on each target.
# Read the weight, horizontal metrics and Unicode coverage from the sfnt,
# decompressing WOFF2 only while inspecting a face that enters the bundle.
class PortableFontFile
  getter weight : Int32
  getter ascent : Float64
  getter descent : Float64
  getter coverage : Set(Int32)

  def self.read(path : String, location : String) : self
    if File.extname(path) == ".woff2"
      directory = File.tempname("mochi-font-", nil)
      Dir.mkdir(directory)
      begin
        copy = File.join(directory, "face.woff2")
        FileUtils.cp(path, copy)
        error = IO::Memory.new
        status = Process.run("woff2_decompress", [copy], output: error, error: error)
        raise "could not decompress WOFF2 (#{error.to_s.strip})" unless status.success?
        return new(File.read(File.join(directory, "face.ttf")).to_slice)
      ensure
        FileUtils.rm_rf(directory)
      end
    end
    new(File.read(path).to_slice)
  rescue ex
    raise "#{location}: cannot inspect font #{File.basename(path).inspect}: #{ex.message}"
  end

  def initialize(bytes : Bytes)
    signature = table_slice(bytes, 0, 4)
    unless signature == Bytes[0, 1, 0, 0] || signature == "OTTO".to_slice
      raise "expected a single static OpenType face"
    end
    tables = {} of String => Bytes
    word(bytes, 4).times do |index|
      at = 12 + index * 16
      name = String.new(table_slice(bytes, at, 4))
      tables[name] = table_slice(bytes, long(bytes, at + 8), long(bytes, at + 12))
    end
    raise "variable fonts require a static face for each weight" if tables.has_key?("fvar")
    @weight = word(tables.fetch("OS/2") { raise "missing OS/2 table" }, 4)
    units = word(tables.fetch("head") { raise "missing head table" }, 18)
    raise "invalid units per em" if units == 0
    metrics = tables.fetch("hhea") { raise "missing hhea table" }
    @ascent = signed_word(metrics, 4) / units
    @descent = -signed_word(metrics, 6) / units
    raise "invalid horizontal metrics" unless @ascent > 0 && @descent >= 0
    @coverage = read_coverage(tables.fetch("cmap") { raise "missing cmap table" })
    raise "empty Unicode character map" if @coverage.empty?
  end

  private def read_coverage(cmap : Bytes) : Set(Int32)
    candidates = [] of Tuple(Int32, Int64)
    word(cmap, 2).times do |index|
      at = 4 + index * 8
      platform = word(cmap, at)
      encoding = word(cmap, at + 2)
      next unless platform == 0 || (platform == 3 && encoding.in?(1, 10))
      offset = long(cmap, at + 4)
      format = word(cmap, offset)
      candidates << {format, offset} if format.in?(4, 12)
    end
    format, offset = candidates.max_by?(&.[0]) || raise "expected a Unicode cmap format 4 or 12"
    coverage = Set(Int32).new
    if format == 12
      table = table_slice(cmap, offset, long(cmap, offset + 4))
      count = long(table, 12)
      raise "truncated cmap format 12" if count > (table.size - 16) // 12
      count.times do |index|
        at = 16 + index * 12
        first, last, glyph = long(table, at), long(table, at + 4), long(table, at + 8)
        raise "invalid cmap code point range" unless first <= last <= 0x10ffff
        first += 1 if glyph == 0
        (first..last).each { |point| coverage << point.to_i }
      end
    else
      table = table_slice(cmap, offset, word(cmap, offset + 2))
      count = word(table, 6) // 2
      starts = 16 + 2 * count
      deltas = starts + 2 * count
      ranges = deltas + 2 * count
      count.times do |index|
        first, last = word(table, starts + 2 * index), word(table, 14 + 2 * index)
        delta = signed_word(table, deltas + 2 * index)
        address = ranges + 2 * index
        relative = word(table, address)
        (first..last).each do |point|
          glyph = relative == 0 ? point : word(table, address + relative + 2 * (point - first))
          coverage << point if (relative == 0 || glyph != 0) && ((glyph + delta) & 0xffff) != 0
        end
      end
    end
    coverage
  end

  private def table_slice(data : Bytes, at, size) : Bytes
    raise "truncated font table" if at > data.size || size > data.size - at
    data[at.to_i, size.to_i]
  end

  private def word(data : Bytes, at) : Int32
    field = table_slice(data, at, 2)
    (field[0].to_i << 8) | field[1].to_i
  end

  private def signed_word(data : Bytes, at) : Int32
    value = word(data, at)
    value >= 0x8000 ? value - 0x10000 : value
  end

  private def long(data : Bytes, at) : Int64
    table_slice(data, at, 4).reduce(0_i64) { |value, byte| (value << 8) | byte }
  end
end
