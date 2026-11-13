# mruby 4.0 opcode numbers; keep executable forms aligned with mochi-gvm.
class RiteVerifier
  OPCODE_LENGTHS = {
      0_u8 => 1, # OP_NOP
      1_u8 => 3, # OP_MOVE
      2_u8 => 3, # OP_LOADL
      3_u8 => 3, # OP_LOADI8
      4_u8 => 3, # OP_LOADINEG
      5_u8 => 2, # OP_LOADI__1
      6_u8 => 2, # OP_LOADI_0
      7_u8 => 2, # OP_LOADI_1
      8_u8 => 2, # OP_LOADI_2
      9_u8 => 2, # OP_LOADI_3
     10_u8 => 2, # OP_LOADI_4
     11_u8 => 2, # OP_LOADI_5
     12_u8 => 2, # OP_LOADI_6
     13_u8 => 2, # OP_LOADI_7
     14_u8 => 4, # OP_LOADI16
     15_u8 => 6, # OP_LOADI32
     16_u8 => 3, # OP_LOADSYM
     17_u8 => 2, # OP_LOADNIL
     18_u8 => 2, # OP_LOADSELF
     19_u8 => 2, # OP_LOADTRUE
     20_u8 => 2, # OP_LOADFALSE
     25_u8 => 3, # OP_GETIV
     26_u8 => 3, # OP_SETIV
     29_u8 => 3, # OP_GETCONST
     30_u8 => 3, # OP_SETCONST
     31_u8 => 3, # OP_GETMCNST
     33_u8 => 4, # OP_GETUPVAR
     34_u8 => 4, # OP_SETUPVAR
     35_u8 => 2, # OP_GETIDX
     36_u8 => 3, # OP_GETIDX0
     37_u8 => 2, # OP_SETIDX
     38_u8 => 3, # OP_JMP
     39_u8 => 4, # OP_JMPIF
     40_u8 => 4, # OP_JMPNOT
     41_u8 => 4, # OP_JMPNIL
     42_u8 => 3, # OP_JMPUW
     47_u8 => 4, # OP_SSEND
     48_u8 => 3, # OP_SSEND0
     49_u8 => 4, # OP_SSENDB
     50_u8 => 4, # OP_SEND
     51_u8 => 3, # OP_SEND0
     52_u8 => 4, # OP_SENDB
     57_u8 => 4, # OP_ENTER
     61_u8 => 2, # OP_RETURN
     63_u8 => 1, # OP_RETSELF
     64_u8 => 1, # OP_RETNIL
     65_u8 => 1, # OP_RETTRUE
     66_u8 => 1, # OP_RETFALSE
     69_u8 => 2, # OP_ADD
     70_u8 => 3, # OP_ADDI
     71_u8 => 2, # OP_SUB
     72_u8 => 3, # OP_SUBI
     73_u8 => 4, # OP_ADDILV
     74_u8 => 4, # OP_SUBILV
     75_u8 => 2, # OP_MUL
     76_u8 => 2, # OP_DIV
     77_u8 => 2, # OP_EQ
     78_u8 => 2, # OP_LT
     79_u8 => 2, # OP_LE
     80_u8 => 2, # OP_GT
     81_u8 => 2, # OP_GE
     82_u8 => 3, # OP_ARRAY
     83_u8 => 4, # OP_ARRAY2
     84_u8 => 2, # OP_ARYCAT
     85_u8 => 3, # OP_ARYPUSH
     87_u8 => 4, # OP_AREF
     91_u8 => 3, # OP_SYMBOL
     92_u8 => 3, # OP_STRING
     93_u8 => 2, # OP_STRCAT
     94_u8 => 3, # OP_HASH
     95_u8 => 3, # OP_HASHADD
     96_u8 => 2, # OP_HASHCAT
     98_u8 => 3, # OP_BLOCK
    103_u8 => 3, # OP_CLASS
    104_u8 => 3, # OP_MODULE
    105_u8 => 3, # OP_EXEC
    107_u8 => 4, # OP_TDEF
    108_u8 => 4, # OP_SDEF
    118_u8 => 1, # OP_STOP
  }

  OPCODE_NAMES = {
     21_u8 => "OP_GETGV",
     22_u8 => "OP_SETGV",
     23_u8 => "OP_GETSV",
     24_u8 => "OP_SETSV",
     27_u8 => "OP_GETCV",
     28_u8 => "OP_SETCV",
     32_u8 => "OP_SETMCNST",
     43_u8 => "OP_EXCEPT",
     44_u8 => "OP_RESCUE",
     45_u8 => "OP_RAISEIF",
     46_u8 => "OP_MATCHERR",
     53_u8 => "OP_CALL",
     54_u8 => "OP_BLKCALL",
     55_u8 => "OP_SUPER",
     56_u8 => "OP_ARGARY",
     58_u8 => "OP_KEY_P",
     59_u8 => "OP_KEYEND",
     60_u8 => "OP_KARG",
     62_u8 => "OP_RETURN_BLK",
     67_u8 => "OP_BREAK",
     68_u8 => "OP_BLKPUSH",
     86_u8 => "OP_ARYSPLAT",
     88_u8 => "OP_ASET",
     89_u8 => "OP_APOST",
     90_u8 => "OP_INTERN",
     97_u8 => "OP_LAMBDA",
     99_u8 => "OP_METHOD",
    100_u8 => "OP_RANGE_INC",
    101_u8 => "OP_RANGE_EXC",
    102_u8 => "OP_OCLASS",
    106_u8 => "OP_DEF",
    109_u8 => "OP_ALIAS",
    110_u8 => "OP_UNDEF",
    111_u8 => "OP_SCLASS",
    112_u8 => "OP_TCLASS",
    113_u8 => "OP_DEBUG",
    114_u8 => "OP_ERR",
    115_u8 => "OP_EXT1",
    116_u8 => "OP_EXT2",
    117_u8 => "OP_EXT3",
  }

  class Unsupported < Exception
    getter irep_index : Int32
    getter pc : Int32
    getter construct : String

    def initialize(@construct, context_name, @irep_index, @pc)
      super("Unsupported GVM construct #{@construct} in #{context_name} (IREP ##{@irep_index} at pc=#{@pc})")
    end
  end

  def self.verify!(bytecode : Bytes, context_name : String) : Nil
    raise "Invalid RITE0400 header in #{context_name}" if bytecode.size < 20 || String.new(bytecode[0, 8]) != "RITE0400"
    offset = 20
    while offset + 8 <= bytecode.size
      section_id = String.new(bytecode[offset, 4])
      size = read_u32_be(bytecode, offset + 4).to_i
      raise "Invalid RITE section in #{context_name}" if size < 8 || size > bytecode.size - offset
      if section_id == "IREP"
        raise "Truncated IREP section in #{context_name}" if size < 12
        at, _ = verify_irep_record!(bytecode, offset + 12, offset + size, context_name, 0)
        raise "Invalid IREP section length in #{context_name}" unless at == offset + size
        return
      end
      offset += size
    end
    raise "Missing IREP section in #{context_name}"
  end

  private def self.verify_irep_record!(bytes : Bytes, cursor : Int32, section_end : Int32,
                                       context : String, index : Int32) : Tuple(Int32, Int32)
    raise "Truncated IREP header in #{context}" if cursor + 16 > section_end
    size = read_u32_be(bytes, cursor).to_i
    children = read_u16_be(bytes, cursor + 8).to_i
    catches = read_u16_be(bytes, cursor + 10).to_i
    length = read_u32_be(bytes, cursor + 12).to_i
    if size < 16 || size > section_end - cursor || length > size - 16
      raise "Invalid IREP length in #{context}"
    end
    if catches > 0
      # Locate the first exception opcode for the authored rescue/ensure line.
      verify_iseq!(bytes[cursor + 16, length], context, index)
      raise Unsupported.new("rescue/ensure handlers", context, index, 0)
    end
    verify_iseq!(bytes[cursor + 16, length], context, index)
    at = cursor + size
    next_index = index + 1
    children.times do
      at, next_index = verify_irep_record!(bytes, at, section_end, context, next_index)
    end
    {at, next_index}
  end

  private def self.verify_iseq!(iseq : Bytes, context : String, index : Int32) : Nil
    pc = 0
    while pc < iseq.size
      op = iseq[pc]
      length = OPCODE_LENGTHS[op]?
      unless length
        name = OPCODE_NAMES[op]? || "OP_UNKNOWN_#{op}"
        construct = case op
                    when 43, 44, 45 then "rescue/ensure (#{name})"
                    when 62         then "nonlocal block return (#{name})"
                    when 67         then "block break (#{name})"
                    else                 name
                    end
        raise Unsupported.new(construct, context, index, pc)
      end
      raise "Truncated instruction #{op} in #{context} (IREP ##{index} at pc=#{pc})" if pc + length > iseq.size
      pc += length
    end
  end

  private def self.read_u16_be(bytes : Bytes, offset : Int32) : UInt16
    (bytes[offset].to_u16 << 8) | bytes[offset + 1].to_u16
  end

  private def self.read_u32_be(bytes : Bytes, offset : Int32) : UInt32
    (bytes[offset].to_u32 << 24) | (bytes[offset + 1].to_u32 << 16) |
      (bytes[offset + 2].to_u32 << 8) | bytes[offset + 3].to_u32
  end
end
