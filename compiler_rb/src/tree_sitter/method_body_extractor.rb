# typed: strict
# frozen_string_literal: true

require_relative "ruby_parser"
require_relative "bindings"
require "sorbet-runtime"

module TreeSitter
  class MethodBodyExtractor
    extend T::Sig

    sig { params(source: String, class_name: String).returns(T::Hash[String, RubyDef]) }
    def self.extract_method_bodies(source, class_name)
      parser = RubyParser.new
      tree = parser.parse(source)
      root = tree.root_node

      methods = T.let({}, T::Hash[String, RubyDef])

      class_node = find_class_by_name(root, class_name)
      return methods unless class_node

      visit_node_for_methods(class_node, class_name, methods, source)
      methods
    ensure
      tree&.close
      parser&.close
    end

    sig { params(node: Node, class_name: String).returns(T.nilable(Node)) }
    private_class_method def self.find_class_by_name(node, class_name)
      if node.type == "class"
        name_node = node.child_by_field_name("name")
        if name_node
          extracted_name = extract_class_name(name_node)
          return node if extracted_name == class_name
        end
      end

      node.each_named_child do |child|
        result = find_class_by_name(child, class_name)
        return result if result
      end

      nil
    end

    sig { params(name_node: Node).returns(String) }
    private_class_method def self.extract_class_name(name_node)
      case name_node.type
      when "constant"
        name_node.text
      when "scope_resolution"
        extract_scope_resolution(name_node)
      else
        ""
      end
    end

    sig { params(node: Node).returns(String) }
    private_class_method def self.extract_scope_resolution(node)
      parts = T.let([], T::Array[String])

      scope = node.child_by_field_name("scope")
      if scope
        case scope.type
        when "constant"
          parts << scope.text
        when "scope_resolution"
          parts << extract_scope_resolution(scope)
        end
      end

      name = node.child_by_field_name("name")
      parts << name.text if name

      parts.join("::")
    end

    sig do
      params(
        node: Node,
        class_name: String,
        methods: T::Hash[String, RubyDef],
        source: String
      ).void
    end
    private_class_method def self.visit_node_for_methods(node, class_name, methods, source)
      if node.type == "method"
        ruby_def = extract_method_def(node, class_name, source)
        methods[ruby_def.name] = ruby_def if ruby_def
      end

      node.each_named_child do |child|
        visit_node_for_methods(child, class_name, methods, source)
      end
    end

    sig { params(method_node: Node, class_name: String, source: String).returns(T.nilable(RubyDef)) }
    private_class_method def self.extract_method_def(method_node, class_name, source)
      name_node = method_node.child_by_field_name("name")
      return nil unless name_node

      method_name = T.must(name_node.text)
      parameters = extract_parameters(method_node)
      body = extract_body_as_lines(method_node, source)

      RubyDef.new(
        name: method_name,
        file_name: "/todo",
        class_name: class_name,
        body: body,
        parameters: parameters
      )
    end

    sig { params(method_node: Node).returns(T::Array[String]) }
    private_class_method def self.extract_parameters(method_node)
      params_node = method_node.child_by_field_name("parameters")
      return [] unless params_node

      parameters = T.let([], T::Array[String])

      params_node.each_named_child do |param|
        case param.type
        when "identifier",
             "optional_parameter",
             "splat_parameter",
             "hash_splat_parameter",
             "block_parameter",
             "keyword_parameter"
          parameters << param.text
        else
          parameters << param.text
        end
      end

      parameters
    end

    sig { params(method_node: Node, source: String).returns(T::Array[String]) }
    private_class_method def self.extract_body_as_lines(method_node, source)
      start_point = TreeSitterBindings.ts_node_start_point(method_node.raw)
      end_point = TreeSitterBindings.ts_node_end_point(method_node.raw)

      source_lines = source.lines
      start_row = start_point[:row].to_i
      end_row = end_point[:row].to_i

      body_lines = T.let([], T::Array[String])

      (start_row..end_row).each do |row|
        if row < source_lines.size
          body_lines << T.must(source_lines[row]).chomp
        end
      end

      body_lines
    end
  end
end
