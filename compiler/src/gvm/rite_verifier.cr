class RiteVerifier
  OPCODE_LENGTHS = {
      0_u8 => 1, # OP_NOP
      1_u8 => 3, # OP_MOVE
      2_u8 => 3, # OP_LOADL
      3_u8 => 3, # OP_LOADI
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
     21_u8 => 3, # OP_GETGV
     22_u8 => 3, # OP_SETGV
     25_u8 => 3, # OP_GETIV
     26_u8 => 3, # OP_SETIV
     27_u8 => 2, # OP_GETIDX
     28_u8 => 3, # OP_GETIDX0
     29_u8 => 2, # OP_SETIDX
     30_u8 => 3, # OP_GETCONST
     31_u8 => 3, # OP_SETCONST
     34_u8 => 4, # OP_GETUPVAR
     35_u8 => 4, # OP_SETUPVAR
     38_u8 => 3, # OP_JMP
     39_u8 => 4, # OP_JMPIF
     40_u8 => 4, # OP_JMPNOT
     41_u8 => 4, # OP_JMPNIL
     47_u8 => 4, # OP_SSEND
     48_u8 => 4, # OP_SSENDB
     49_u8 => 4, # OP_SEND
     50_u8 => 4, # OP_SENDB
     55_u8 => 4, # OP_ENTER
     58_u8 => 2, # OP_RETURN
     59_u8 => 2, # OP_RETURN_BLK
     60_u8 => 1, # OP_RETSELF
     61_u8 => 1, # OP_RETTRUE
     62_u8 => 1, # OP_RETFALSE
     63_u8 => 1, # OP_RETNIL
     64_u8 => 2, # OP_BREAK
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
     23_u8 => "OP_GETSV",
     24_u8 => "OP_SETSV",
     32_u8 => "OP_GETMCNST",
     33_u8 => "OP_SETMCNST",
     36_u8 => "OP_GETCV",
     37_u8 => "OP_SETCV",
     42_u8 => "OP_JMPUW",
     43_u8 => "OP_EXCEPT",
     44_u8 => "OP_RESCUE",
     45_u8 => "OP_RAISEIF",
     46_u8 => "OP_SSEND0",
     51_u8 => "OP_CALL",
     52_u8 => "OP_SUPER",
     53_u8 => "OP_ARGARY",
     54_u8 => "OP_KARG",
     56_u8 => "OP_KEY_P",
     57_u8 => "OP_KEYEND",
     65_u8 => "OP_BLKPUSH",
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
    109_u8 => "OP_EXT1",
    110_u8 => "OP_EXT2",
    111_u8 => "OP_EXT3",
  }

  def self.verify!(bytecode : Bytes, context_name : String) : Nil
    return if bytecode.size < 34
    return unless String.new(bytecode[0, 8]) == "RITE0400"

    offset = 22
    while offset + 8 <= bytecode.size
      section_id = String.new(bytecode[offset, 4])
      section_size = read_u32_be(bytecode, offset + 4).to_i
      break if section_size < 8 || offset + section_size > bytecode.size

      if section_id == "IREP"
        verify_irep_section!(bytecode, offset + 12, offset + section_size, context_name)
        return
      end

      break if section_id == "END\u0000"
      offset += section_size
    end
  end

  private def self.verify_irep_section!(bytecode : Bytes, cursor : Int32, section_end : Int32, context_name : String) : Nil
    irep_index = 0
    at = cursor
    while at < section_end
      at, _ = verify_irep_record!(bytecode, at, section_end, context_name, irep_index)
      irep_index += 1
      break if at >= section_end
    end
  end

  private def self.verify_irep_record!(
    bytecode : Bytes,
    cursor : Int32,
    section_end : Int32,
    context_name : String,
    irep_index : Int32,
  ) : Tuple(Int32, Int32)
    raise "Truncated IREP header in #{context_name}" if cursor + 16 > section_end

    child_count = read_u16_be(bytecode, cursor + 8).to_i
    catch_count = read_u16_be(bytecode, cursor + 10).to_i
    iseq_len = read_u32_be(bytecode, cursor + 12).to_i

    iseq_start = cursor + 16
    catch_bytes = catch_count * 13
    iseq_end = iseq_start + iseq_len
    pool_start = iseq_end + catch_bytes
    raise "Truncated IREP instruction sequence in #{context_name}" if pool_start > section_end

    verify_iseq!(bytecode[iseq_start, iseq_len], context_name, irep_index)

    at = skip_pool_and_syms!(bytecode, pool_start, section_end, context_name)
    next_index = irep_index + 1
    child_count.times do
      at, next_index = verify_irep_record!(bytecode, at, section_end, context_name, next_index)
    end
    {at, next_index}
  end

  private def self.verify_iseq!(iseq : Bytes, context_name : String, irep_index : Int32) : Nil
    pc = 0
    while pc < iseq.size
      op = iseq[pc]
      len = OPCODE_LENGTHS[op]?
      unless len
        name = OPCODE_NAMES[op]? || "OP_UNKNOWN_#{op}"
        raise "Unsupported GVM opcode #{name} (#{op}) in #{context_name} (IREP ##{irep_index} at pc=#{pc})"
      end
      if pc + len > iseq.size
        raise "Truncated instruction #{op} in #{context_name} (IREP ##{irep_index} at pc=#{pc})"
      end
      pc += len
    end
  end

  private def self.skip_pool_and_syms!(bytecode : Bytes, cursor : Int32, section_end : Int32, context_name : String) : Int32
    raise "Truncated IREP pool header in #{context_name}" if cursor + 2 > section_end
    pool_count = read_u16_be(bytecode, cursor).to_i
    at = cursor + 2

    pool_count.times do
      raise "Truncated IREP pool entry in #{context_name}" if at >= section_end
      tt = bytecode[at]
      at += 1
      if (tt & 0x03) == 0 || (tt & 0x03) == 2
        str_len = (tt >> 2).to_i
        if str_len == 0x3F
          raise "Truncated IREP pool string length in #{context_name}" if at + 2 > section_end
          str_len = read_u16_be(bytecode, at).to_i
          at += 2
        end
        at += str_len + 1
      elsif tt == 1 || tt == 3
        at += 4
      elsif tt == 5 || tt == 7 || tt == 9
        at += 8
      else
        raise "Unsupported IREP pool entry type #{tt} in #{context_name}"
      end
      raise "Truncated IREP pool entry payload in #{context_name}" if at > section_end
    end

    raise "Truncated IREP syms header in #{context_name}" if at + 2 > section_end
    syms_count = read_u16_be(bytecode, at).to_i
    at += 2
    syms_count.times do
      raise "Truncated IREP symbol entry in #{context_name}" if at + 2 > section_end
      sym_len = read_u16_be(bytecode, at).to_i
      at += 2
      at += sym_len + 1 unless sym_len == 0xFFFF
      raise "Truncated IREP symbol payload in #{context_name}" if at > section_end
    end

    at
  end

  private def self.read_u16_be(bytes : Bytes, offset : Int32) : UInt16
    (bytes[offset].to_u16 << 8) | bytes[offset + 1].to_u16
  end

  private def self.read_u32_be(bytes : Bytes, offset : Int32) : UInt32
    (bytes[offset].to_u32 << 24) |
      (bytes[offset + 1].to_u32 << 16) |
      (bytes[offset + 2].to_u32 << 8) |
      bytes[offset + 3].to_u32
  end
end
