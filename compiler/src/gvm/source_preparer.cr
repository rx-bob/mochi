require "../tree-sitter/ruby_parser"

# Removes class-body instance variables before compiling a component with mrbc.
#
# The Ruby backend keeps `@tag_name` and typed ivar declarations at class level
# as metadata. mochi-gvm only models instance state, so executing those class
# body reads and writes fails with `type mismatch`. They are never read by
# instance methods and can be dropped safely. Instance variables inside method
# definitions are preserved.
class GvmSourcePreparer
  def self.strip_class_ivars(source : String) : String
    parser = TreeSitter::RubyParser.new
    parsed = parser.parse(source)
    ranges = [] of Tuple(Int32, Int32)
    visit(parsed.root_node, ranges)
    return source if ranges.empty?

    builder = String::Builder.new
    cursor = 0
    ranges.sort_by! { |range| range[0] }
    ranges.each do |(start_byte, end_byte)|
      next if end_byte <= cursor
      builder << source.byte_slice(cursor, start_byte - cursor) if start_byte > cursor
      cursor = end_byte
    end
    builder << source.byte_slice(cursor, source.bytesize - cursor) if cursor < source.bytesize
    builder.to_s
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
    return false unless node.type == "assignment"

    left = node.child_by_field_name("left")
    !left.nil? && left.not_nil!.type == "instance_variable"
  end
end
