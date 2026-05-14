# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "ruby_parser"

module TreeSitter
  class InstanceVarAnalyzer
    class Category < T::Enum
      enums do
        State = new
        Constant = new
        Derived = new
      end
    end

    class VariableInfo < T::Struct
      extend T::Sig

      const :name, String
      prop :writes, Integer, default: 0
      prop :reads, Integer, default: 0
      prop :is_bound, T::Boolean, default: false
      prop :attr_mutated, T::Boolean, default: false
      prop :initialized_in_constructor, T::Boolean, default: false
      prop :written_outside_constructor, T::Boolean, default: false

      sig { returns(Category) }
      def category
        if attr_mutated || written_outside_constructor
          Category::State
        elsif initialized_in_constructor && !written_outside_constructor
          Category::Constant
        else
          Category::Derived
        end
      end
    end

    extend T::Sig

    sig { params(source: String).returns(T::Array[VariableInfo]) }
    def self.analyze(source)
      parser = RubyParser.new
      tree = parser.parse(source)
      root = tree.root_node

      variables = T.let({}, T::Hash[String, VariableInfo])

      visit_node(root, variables, nil)

      variables.values.to_a
    ensure
      tree&.close
      parser&.close
    end

    sig do
      params(
        node: Node,
        variables: T::Hash[String, VariableInfo],
        current_method: T.nilable(String),
        is_write: T::Boolean
      ).void
    end
    private_class_method def self.visit_node(node, variables, current_method, is_write = false)
      # Update current method
      if node.type == "method"
        name_node = node.child_by_field_name("name")
        if name_node
          current_method = name_node.text
        end
      end

      # 1. Handle attr_accessor / attr_writer / attr_reader
      method_name = nil
      args_node = nil

      if node.type == "call"
        method_name_node = node.child_by_field_name("method")
        method_name = method_name_node ? method_name_node.text : nil
        args_node = node.child_by_field_name("arguments")
      elsif node.type == "command"
        method_name_node = node.child_by_field_name("name")
        method_name = method_name_node ? method_name_node.text : nil
        args_node = node.child_by_field_name("arguments")
      end

      if method_name && ["attr_accessor", "attr_writer", "attr_reader"].include?(method_name)
        if args_node
          args_node.each_named_child do |arg|
            if arg.type == "simple_symbol"
              # Strip the leading ':' and prefix with '@'
              var_name = "@#{arg.text.delete_prefix(":")}"
              var_info = get_var(variables, var_name)
              if method_name == "attr_accessor" || method_name == "attr_writer"
                var_info.attr_mutated = true
              end
              if method_name == "attr_accessor" || method_name == "attr_reader"
                # Assuming it's readable
                var_info.reads += 1
              end
            end
          end
        end
      end

      # 2. Handle assignments and reads for instance_variables
      if ["assignment", "operator_assignment"].include?(node.type)
        left_node = node.child_by_field_name("left")
        right_node = node.child_by_field_name("right")

        if left_node
          visit_node(left_node, variables, current_method, true)
        end
        if right_node
          visit_node(right_node, variables, current_method, false)
        end
        return # prevent double traversal
      end

      if node.type == "instance_variable"
        var_name = node.text
        var_info = get_var(variables, var_name)

        if current_method == "html"
          var_info.is_bound = true
        end

        if is_write
          var_info.writes += 1
          if current_method == "initialize"
            var_info.initialized_in_constructor = true
          else
            var_info.written_outside_constructor = true
          end
        else
          var_info.reads += 1
        end
      end

      # 3. Handle string_content for interpolations inside html
      if current_method == "html" && node.type == "string_content"
        content = node.text

        # Scan for anything inside braces
        content.scan(/\{([^}]+)\}/) do |match|
          inner = match[0].strip

          # Skip control flow
          next if inner.start_with?("if ") || inner.start_with?("each ") || inner.start_with?("elsif ") || inner.start_with?("unless ") || inner == "else" || inner == "end"

          # Handle explicit instance var: {@var}
          if inner =~ /^@[a-zA-Z0-9_]+$/
            var_name = inner
            var_info = get_var(variables, var_name)
            var_info.is_bound = true
            var_info.reads += 1
            next
          end

          # Handle implicit var: {var}
          if inner =~ /^[a-zA-Z0-9_]+$/
            name = inner
            # implicit binding
            keywords = ["if", "else", "elsif", "end", "unless", "while", "until", "case", "when", "then", "do", "begin", "rescue", "true", "false", "nil", "self", "super"]
            unless keywords.include?(name)
              var_name = "@#{name}"
              var_info = get_var(variables, var_name)
              var_info.is_bound = true
              var_info.reads += 1
            end
          end
        end
      end

      # Standard ruby #{} interpolation nodes contain `interpolation` nodes, which we traverse into normally.

      # Traverse children
      node.each_named_child do |child|
        visit_node(child, variables, current_method, false)
      end
    end

    sig { params(variables: T::Hash[String, VariableInfo], name: String).returns(VariableInfo) }
    private_class_method def self.get_var(variables, name)
      variables[name] ||= VariableInfo.new(name: name)
    end
  end
end
