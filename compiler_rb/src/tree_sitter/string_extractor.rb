# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "ruby_parser"

module TreeSitter
  class StringExtractor
    extend T::Sig

    sig { params(body: T::Array[String], name: String).returns(String) }
    def self.extract_raw_string_from_def_body(body, name)
      method_source = body.join("\n")

      parser = RubyParser.new
      tree = parser.parse(method_source)
      root = tree.root_node

      method_node = find_method_node(root)
      return extract_from_fallback(body) unless method_node

      extract_string_from_method_node(method_node) || extract_from_fallback(body)
    ensure
      tree&.close
      parser&.close
    end

    sig { params(method_node: Node).returns(T.nilable(String)) }
    def self.extract_string_from_method_node(method_node)
      return nil unless method_node.type == "method"

      body_node = method_node.child_by_field_name("body")
      return nil unless body_node

      string_node = find_string_in_body(body_node)
      return nil unless string_node

      extract_string_content(string_node)
    end

    sig { params(node: Node).returns(T.nilable(Node)) }
    private_class_method def self.find_method_node(node)
      return node if node.type == "method"

      node.each_named_child do |child|
        result = find_method_node(child)
        return result if result
      end

      nil
    end

    sig { params(body_node: Node).returns(T.nilable(Node)) }
    private_class_method def self.find_string_in_body(body_node)
      if body_node.named_child_count == 1
        first_child = body_node.named_child(0)

        case first_child.type
        when "string"
          return first_child
        when "heredoc_body"
          return first_child
        when "array"
          return first_child
        when "return"
          arg_node = first_child.named_child(0)
          if arg_node && (arg_node.type == "string" || arg_node.type.start_with?("heredoc"))
            return arg_node
          end
        when "call"
          receiver = first_child.child_by_field_name("receiver")
          if receiver && (receiver.type == "string" || receiver.type.start_with?("heredoc"))
            return receiver
          end
        end
      end

      find_first_string_node(body_node)
    end

    sig { params(node: Node).returns(T.nilable(Node)) }
    private_class_method def self.find_first_string_node(node)
      return node if node.type == "string" || node.type.start_with?("heredoc")

      node.each_named_child do |child|
        result = find_first_string_node(child)
        return result if result
      end

      nil
    end

    sig { params(string_node: Node).returns(String) }
    private_class_method def self.extract_string_content(string_node)
      case string_node.type
      when "string"
        extract_regular_string_content(string_node)
      when "heredoc_body"
        string_node.text
      when "array"
        string_node.text
      else
        string_node.text
      end
    end

    sig { params(string_node: Node).returns(String) }
    private_class_method def self.extract_regular_string_content(string_node)
      full_text = string_node.text
      is_percent_string = full_text.start_with?("%Q{") || full_text.start_with?("%q{")

      content_parts = T.let([], T::Array[String])

      string_node.each_child do |child|
        case child.type
        when "string_content"
          content_parts << child.text
        when "interpolation"
          content_parts << child.text
        when "escape_sequence"
          content_parts << child.text
        end
      end

      if content_parts.empty?
        return strip_quote_delimiters(full_text)
      end

      result = content_parts.join

      if is_percent_string
        normalize_whitespace(result.strip)
      else
        result
      end
    end

    sig { params(text: String).returns(String) }
    private_class_method def self.normalize_whitespace(text)
      text.gsub("  ", " ")
    end

    sig { params(text: String).returns(String) }
    private_class_method def self.strip_quote_delimiters(text)
      if text.start_with?("%Q{") && text.end_with?("}")
        normalize_whitespace(text[3...-1].strip)
      elsif text.start_with?("%q{") && text.end_with?("}")
        normalize_whitespace(text[3...-1].strip)
      elsif text.start_with?('"') && text.end_with?('"')
        text[1...-1]
      elsif text.start_with?("'") && text.end_with?("'")
        text[1...-1]
      else
        text
      end
    end

    sig { params(body: T::Array[String]).returns(String) }
    private_class_method def self.extract_from_fallback(body)
      return "" if body.size < 2

      inner_body = body[1...body.size - 1]
        .join("\n")
        .strip

      if inner_body.start_with?("%Q{") && inner_body.end_with?("}")
        normalize_whitespace(inner_body[3...-1].strip)
      elsif inner_body.start_with?("%q{") && inner_body.end_with?("}")
        normalize_whitespace(inner_body[3...-1].strip)
      elsif inner_body.start_with?('"') && inner_body.end_with?('"')
        inner_body[1...-1]
      elsif inner_body.start_with?("'") && inner_body.end_with?("'")
        inner_body[1...-1]
      else
        inner_body
      end
    end
  end
end
