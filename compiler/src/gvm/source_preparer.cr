require "../tree-sitter/ruby_parser"
require "./computed_source"

# Removes class-body instance variables before compiling a component with mrbc.
#
# The Ruby backend keeps `@tag_name` and typed ivar declarations at class level
# as metadata. mochi-gvm only models instance state, so executing those class
# body reads and writes fails with `type mismatch`. They are never read by
# instance methods and can be dropped safely. Instance variables inside method
# definitions are preserved.
class GvmSourcePreparer
  def self.validate_control_flow!(source : String, path : String, line_offset : Int32 = 1) : Nil
    parsed = TreeSitter::RubyParser.new.parse(source)
    reject_redo(parsed.root_node, path, line_offset)
  end

  private def self.reject_redo(node : TreeSitter::Node, path : String, line_offset : Int32) : Nil
    if node.type == "redo"
      line = node.start_point.row + line_offset
      raise "#{path}:#{line}: unsupported redo"
    end
    node.each_named_child { |child| reject_redo(child, path, line_offset) }
  end

  def self.strip_class_ivars(source : String, path : String = "(component)", offset : Int32 = 1) : String
    source = ComputedSource.prepare(source, path, offset)
    parser = TreeSitter::RubyParser.new
    parsed = parser.parse(source)
    ranges = [] of Tuple(Int32, Int32)
    # The package graph resolves top-level imports before compilation. Their
    # dependencies are loaded before this package; no runtime require exists.
    parsed.root_node.each_named_child do |node|
      ranges << {node.start_byte, node.end_byte} if static_import?(node)
    end
    visit(parsed.root_node, ranges)
    return source if ranges.empty?

    builder = String::Builder.new
    cursor = 0
    ranges.sort_by! { |range| range[0] }
    ranges.each do |(start_byte, end_byte)|
      next if end_byte <= cursor
      builder << source.byte_slice(cursor, start_byte - cursor) if start_byte > cursor
      # Keep newlines so mrbc line numbers still match the original file.
      removed = source.byte_slice(start_byte, end_byte - start_byte)
      removed.each_byte do |byte|
        if byte == 10_u8
          builder << '\n'
        else
          builder << ' '
        end
      end
      cursor = end_byte
    end
    builder << source.byte_slice(cursor, source.bytesize - cursor) if cursor < source.bytesize
    builder.to_s
  end

  private def self.static_import?(node : TreeSitter::Node) : Bool
    return false unless node.type == "call" || node.type == "command"
    return false unless node.child_by_field_name("receiver").nil?
    method = node.child_by_field_name("method") || node.child_by_field_name("name")
    return false unless method && method.text.in?("require", "require_relative")
    arguments = node.child_by_field_name("arguments")
    return false unless arguments
    children = [] of TreeSitter::Node
    arguments.each_named_child { |child| children << child }
    return false unless children.size == 1 && children.first.type == "string"
    literal = true
    children.first.each_named_child { |child| literal = false if child.type == "interpolation" }
    literal
  end

  private def self.visit(node : TreeSitter::Node, ranges : Array(Tuple(Int32, Int32))) : Nil
    if node.type == "class" || node.type == "module"
      body = node.child_by_field_name("body")
      collect_body(body, ranges) if body
    end

    node.each_named_child do |child|
      visit(child, ranges)
    end
  end

  private def self.collect_body(body : TreeSitter::Node, ranges : Array(Tuple(Int32, Int32))) : Nil
    if class_ivar_statement?(body)
      ranges << {body.start_byte, body.end_byte}
      return
    end

    body.each_named_child do |child|
      if class_ivar_statement?(child)
        ranges << {child.start_byte, child.end_byte}
      end
    end
  end

  private def self.class_ivar_statement?(node : TreeSitter::Node) : Bool
    return true if node.type == "instance_variable"
    return true if metadata_declaration?(node)
    return false unless node.type == "assignment"

    left = node.child_by_field_name("left")
    !left.nil? && left.not_nil!.type == "instance_variable"
  end

  # `prop` and `event` declarations are compile-time metadata. The generated
  # mount/emit methods own their runtime behavior, so the declarations must not
  # execute as class-body calls in the VM.
  private def self.metadata_declaration?(node : TreeSitter::Node) : Bool
    return false unless node.type == "call" || node.type == "command"
    return false unless node.child_by_field_name("receiver").nil?

    method = node.child_by_field_name("method")
    return false if method.nil?
    name = method.not_nil!.text
    name == "prop" || name == "event"
  end
end
