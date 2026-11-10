require "../tree-sitter/ruby_parser"

class InjectUtils
  def self.find_insertion_point(ruby_code : String, class_name : String, end_keyword : String, fallback_offset : Int32) : Int32?
    if class_end = InjectUtils.find_class_end_line_start(ruby_code, class_name)
      return class_end
    end

    second_last_end = InjectUtils.find_second_last_end(ruby_code, end_keyword)

    unless second_last_end
      STDERR.puts "Warning: Could not find insertion point for methods in class #{class_name}"
      return nil
    end

    return InjectUtils.calculate_insertion_point(ruby_code, second_last_end, fallback_offset)
  end

  # Returns the byte offset of the line that holds the class's closing `end`.
  # Tree-sitter identifies the class node, so a literal `end` inside an HTML or
  # CSS string can never be mistaken for the class terminator.
  def self.find_class_end_line_start(ruby_code : String, class_name : String) : Int32?
    parser = TreeSitter::RubyParser.new
    tree = parser.parse(ruby_code)
    class_node = InjectUtils.find_class_node(tree.root_node, class_name)
    return nil unless class_node

    end_keyword_start = class_node.end_byte - 3
    return nil if end_keyword_start < 0
    return nil unless ruby_code.byte_slice(end_keyword_start, 3) == "end"

    InjectUtils.line_start_byte(ruby_code, end_keyword_start)
  end

  def self.find_second_last_end(text : String, end_keyword : String) : Int32?
    last_end = text.rindex(end_keyword)
    return nil unless last_end && last_end > 0

    second_last = text.rindex(end_keyword, last_end - 1)
    return nil unless second_last

    InjectUtils.char_to_byte_index(text, second_last)
  end

  # calculate exact insertion point (after the line containing the end keyword)
  def self.calculate_insertion_point(code : String, end_position : Int32, fallback_offset : Int32) : Int32
    newline_after = InjectUtils.byte_index(code, 10_u8, end_position)
    newline_after ? newline_after + 1 : Math.min(end_position + fallback_offset, code.bytesize)
  end

  def self.insert_code(original : String, position : Int32, code_to_insert : String) : String
    return original if position < 0 || position > original.bytesize

    String.build do |io|
      io.write original.to_slice[0, position]
      io << code_to_insert
      io.write original.to_slice[position, original.bytesize - position]
    end
  end

  def self.find_class_node(node : TreeSitter::Node, class_name : String) : TreeSitter::Node?
    if node.type == "class"
      name_node = node.child_by_field_name("name")
      return node if name_node && name_node.text == class_name
    end

    node.each_named_child do |child|
      if found = InjectUtils.find_class_node(child, class_name)
        return found
      end
    end

    nil
  end

  # All offsets crossing into Tree-sitter land are byte offsets. Crystal's
  # String#index/rindex return character offsets, so these helpers keep the
  # two worlds from disagreeing on source that contains multibyte characters.
  def self.line_start_byte(text : String, byte_offset : Int32) : Int32
    bytes = text.to_slice
    index = Math.min(byte_offset, bytes.size)

    while index > 0
      return index if bytes[index - 1] == 10_u8
      index -= 1
    end

    0
  end

  def self.byte_index(text : String, byte : UInt8, start_byte : Int32) : Int32?
    bytes = text.to_slice
    index = Math.max(start_byte, 0)

    while index < bytes.size
      return index if bytes[index] == byte
      index += 1
    end

    nil
  end

  def self.char_to_byte_index(text : String, char_index : Int32) : Int32
    return text.bytesize if char_index >= text.size

    text[0, char_index].bytesize
  end
end
