require "../tree-sitter/ruby_parser"
require "set"

# Explicit component projections. Only declarations are lowered; method bodies
# retain their authored lines and names for the existing runtime source maps.
class ComputedSource
  record Declaration, node : TreeSitter::Node, name : String, dependencies : Array(String)

  def self.prepare(source : String, path : String, offset : Int32 = 1, erase : Bool = false) : String
    return source unless source.includes?("computed")
    tree = TreeSitter::RubyParser.new.parse(source)
    edits = [] of Tuple(Int32, Int32, String)
    visit(tree.root_node, path, offset, erase, edits)
    edits.sort_by { |edit| -edit[0] }.each do |start, finish, replacement|
      source = source.byte_slice(0, start) + replacement + source.byte_slice(finish)
    end
    source
  end

  private def self.fail_at(node : TreeSitter::Node, path : String, offset : Int32, message : String) : NoReturn
    raise "#{path}:#{node.start_point.row + offset}: computed #{message}"
  end

  private def self.children(node : TreeSitter::Node) : Array(TreeSitter::Node)
    result = [] of TreeSitter::Node
    node.each_named_child { |child| result << child }
    result
  end

  private def self.visit(node, path, offset, erase, edits) : Nil
    if node.type == "class" && (body = node.child_by_field_name("body"))
      declarations = {} of String => Declaration
      methods = {} of String => TreeSitter::Node
      roots = Set(String).new
      collect_roots(body, roots)
      children(body).each do |child|
        if child.type == "method"
          methods[child.child_by_field_name("name").not_nil!.text] = child
        end
        next unless child.type.in?("call", "command") && child.child_by_field_name("receiver").nil?
        next unless child.child_by_field_name("method").try(&.text) == "computed"
        args = child.child_by_field_name("arguments").try { |a| children(a) } || [] of TreeSitter::Node
        unless args.size == 2 && args[0].type == "simple_symbol" && args[1].type == "pair" &&
               args[1].child_by_field_name("key").try(&.text) == "depends_on"
          fail_at(child, path, offset, "expects :method, depends_on: [:@root, :other_computed]")
        end
        deps = args[1].child_by_field_name("value").not_nil!
        unless deps.type == "array" && children(deps).all? { |dep| dep.type == "simple_symbol" }
          fail_at(deps, path, offset, "dependencies must be literal symbols")
        end
        name = args[0].text.lchop(':')
        fail_at(child, path, offset, "cannot declare initialize") if name == "initialize"
        fail_at(child, path, offset, "duplicate declaration #{name}") if declarations.has_key?(name)
        declarations[name] = Declaration.new(child, name, children(deps).map { |dep| dep.text.lchop(':') }.uniq)
      end
      flattened = {} of String => Array(String)
      declarations.each do |name, declaration|
        method = methods[name]?
        fail_at(declaration.node, path, offset, "unknown method #{name}") unless method
        if params = method.child_by_field_name("parameters")
          fail_at(params, path, offset, "method #{name} must take no arguments") unless children(params).empty?
        end
        resolved = flatten(name, declarations, roots, flattened, Set(String).new, path, offset)
        fail_at(declaration.node, path, offset, "#{name} exceeds 256 root dependencies") if resolved.size > 256
      end
      declarations.each do |name, declaration|
        validate_body(methods[name], name, methods, declarations, flattened[name].to_set,
          declaration.dependencies.to_set, Set(String).new, path, offset)
        original = declaration.node.text
        replacement = if erase
                        original.gsub(/[^\n]/, " ")
                      else
                        "__mochi_computed(:#{name}, [#{flattened[name].map { |dep| ":#{dep}" }.join(", ")}])" + "\n" * original.count('\n')
                      end
        edits << {declaration.node.start_byte, declaration.node.end_byte, replacement}
      end
    end
    node.each_named_child { |child| visit(child, path, offset, erase, edits) }
  end

  private def self.collect_roots(node, roots) : Nil
    roots << node.text if node.type == "instance_variable" && node.text != "@tag_name"
    # Props may not have an authored read until a template is generated.
    if node.type == "call" && node.child_by_field_name("method").try(&.text) == "prop"
      args = node.child_by_field_name("arguments")
      first = args.try { |a| children(a).first? }
      roots << "@#{first.text.lchop(':')}" if first && first.type == "simple_symbol"
    end
    node.each_named_child { |child| collect_roots(child, roots) }
  end

  private def self.flatten(name, declarations, roots, flattened, visiting, path, offset) : Array(String)
    return flattened[name] if flattened.has_key?(name)
    declaration = declarations[name]
    fail_at(declaration.node, path, offset, "dependency cycle at #{name}") if visiting.includes?(name)
    visiting << name
    result = [] of String
    declaration.dependencies.each do |dep|
      if dep.starts_with?('@') && roots.includes?(dep)
        result << dep
      elsif declarations.has_key?(dep)
        result.concat(flatten(dep, declarations, roots, flattened, visiting, path, offset))
      else
        fail_at(declaration.node, path, offset, "unknown dependency #{dep} for #{name}")
      end
    end
    visiting.delete(name)
    flattened[name] = result.uniq
  end

  private def self.collect_local_targets(node, locals) : Nil
    if node.type == "identifier"
      locals << node.text
    elsif node.type.in?("method_parameters", "block_parameters", "left_assignment_list", "destructured_left_assignment", "rest_assignment")
      node.each_named_child { |child| collect_local_targets(child, locals) }
    elsif name = node.child_by_field_name("name")
      locals << name.text if name.type == "identifier"
    end
  end

  private def self.state_target?(node) : Bool
    return true if node.type.in?("instance_variable", "class_variable", "global_variable", "constant")
    return true if node.type == "element_reference" && node.text.starts_with?('@')
    return children(node).any? { |child| state_target?(child) } if node.type.in?("left_assignment_list", "destructured_left_assignment", "rest_assignment")
    false
  end

  private def self.validate_body(node, owner, methods, declarations, roots, dependencies, visited, path, offset, locals = Set(String).new) : Nil
    if node.type == "method"
      locals = Set(String).new
      if params = node.child_by_field_name("parameters")
        collect_local_targets(params, locals)
        validate_body(params, owner, methods, declarations, roots, dependencies, visited, path, offset, locals)
      end
      if body = node.child_by_field_name("body")
        validate_body(body, owner, methods, declarations, roots, dependencies, visited, path, offset, locals)
      end
      return
    end
    if node.type.in?("block", "do_block")
      locals = locals.dup
      if params = node.child_by_field_name("parameters")
        collect_local_targets(params, locals)
      end
    end
    if node.type == "instance_variable" && !roots.includes?(node.text)
      fail_at(node, path, offset, "undeclared dependency #{node.text} in #{owner}")
    end
    if node.type.in?("assignment", "operator_assignment", "multiple_assignment")
      left = node.child_by_field_name("left")
      collect_local_targets(left, locals) if left
      if left && state_target?(left)
        fail_at(node, path, offset, "#{owner} must not write state")
      end
    end
    if node.type.in?("call", "command", "identifier")
      receiver = node.child_by_field_name("receiver")
      name = node.type == "identifier" ? node.text : (node.child_by_field_name("method").try(&.text) || "")
      local = node.type == "identifier" && locals.includes?(name)
      if (!local && name == "emit") || receiver.try(&.text) == "Mochi" ||
         (receiver.try(&.type) == "instance_variable" && name.in?("<<", "push", "pop", "clear", "delete", "[]=", "concat"))
        fail_at(node, path, offset, "#{owner} must not emit effects or mutate state")
      end
      if (receiver.nil? || receiver.try(&.text) == "self") && !local
        if declarations.has_key?(name)
          fail_at(node, path, offset, "undeclared dependency #{name} in #{owner}") unless dependencies.includes?(name)
        elsif methods.has_key?(name) && !visited.includes?(name)
          visited << name
          validate_body(methods[name], owner, methods, declarations, roots, dependencies, visited, path, offset)
        end
      end
    end
    node.each_named_child do |child|
      next if node.type.in?("call", "command") && node.child_by_field_name("method").try(&.start_byte) == child.start_byte
      validate_body(child, owner, methods, declarations, roots, dependencies, visited, path, offset, locals)
    end
  end
end
