# Reads mrbc -g line tables only when verification rejects a program. Debug
# sections never enter shipped .chi files or the normal compilation path.
class RiteDebugInfo
  def self.line_for(bytes : Bytes, irep : Int32, pc : Int32) : Int32?
    new(bytes).line_for(irep, pc)
  end

  def initialize(@bytes : Bytes)
    @at = 20
  end

  def line_for(irep : Int32, pc : Int32) : Int32?
    while @at + 8 <= @bytes.size
      start = @at
      name = String.new(@bytes[@at, 4])
      @at += 4
      size = u32.to_i
      return nil if size < 8 || size > @bytes.size - start
      return debug_line(irep, pc, start + size) if name == "DBG\0"
      @at = start + size
    end
    nil
  end

  private def debug_line(irep, pc, section_end) : Int32?
    u16.times { skip(u16.to_i) }
    irep.times do
      start = @at
      size = u32.to_i
      return nil if size < 6 || size > section_end - start
      @at = start + size
    end
    start = @at
    size = u32.to_i
    return nil if size < 6 || size > section_end - start
    result = nil.as(Int32?)
    u16.times do
      first_pc = u32
      u16 # filename index; caller supplies the authored path
      count = u32.to_i
      type = u8
      case type
      when 0
        count.times do |index|
          line = u16.to_i
          result = line if first_pc + index == pc
        end
      when 1
        count.times do
          entry_pc = u32
          line = u16.to_i
          result = line if entry_pc <= pc
        end
      when 2
        # count is byte length for the packed delta map, not entry count.
        finish = @at + count
        entry_pc = 0_u32
        line = 0_u32
        while @at < finish
          entry_pc = entry_pc &+ packed
          line = line &+ packed
          result = line.to_i if entry_pc <= pc
        end
      else
        return nil
      end
    end
    result
  end

  private def skip(count)
    raise "Truncated RITE debug data" if count < 0 || count > @bytes.size - @at
    @at += count
  end

  private def u8 : UInt8
    skip(1)
    @bytes[@at - 1]
  end

  private def u16 : UInt16
    (u8.to_u16 << 8) | u8.to_u16
  end

  private def u32 : UInt32
    (u16.to_u32 << 16) | u16.to_u32
  end

  private def packed : UInt32
    result = 0_u32
    5.times do |index|
      byte = u8
      result |= (byte & 0x7f).to_u32 << (index * 7)
      return result if byte < 0x80
    end
    raise "Invalid RITE debug integer"
  end
end
