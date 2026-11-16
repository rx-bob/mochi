require "./ruby_parser"
require "./bindings"

module TreeSitter
  class StringExtractor
    def self.extract_raw_string_from_def_body(body : Array(String), name : String) : String
      method_source = body.join("\n")

      parser = RubyParser.new
      tree = parser.parse(method_source)
      root = tree.root_node

      method_node = find_method_node(root)
      return extract_from_fallback(body) unless method_node

      return extract_string_from_method_node(method_node) || extract_from_fallback(body)
    end

    def self.extract_string_from_method_node(method_node : Node) : String?
      return nil unless method_node.type == "method"

      body_node = method_node.child_by_field_name("body")
      return nil unless body_node

      string_node = find_string_in_body(body_node)
      return nil unless string_node

      return extract_string_content(string_node)
    end

    # Returns the raw byte range of one literal node's contents. This is the
    # string-node counterpart to `string_source_range`, used by lint's
    # tolerant literal-require scanner.
    def self.string_content_range(string_node : Node) : Tuple(Int32, Int32)?
      content_range(string_node)
    end

    # Returns the literal node chosen for a method body. Lint keeps this node
    # so it can map template bytes back to the authored source without
    # searching for repeated text.
    def self.string_node_from_method_node(method_node : Node) : Node?
      return nil unless method_node.type == "method"

      body_node = method_node.child_by_field_name("body")
      return nil unless body_node

      find_string_in_body(body_node)
    end

    # Returns the byte range of the literal's contents (without Ruby quote or
    # percent delimiters) in the original source. Heredoc content excludes its
    # terminator so a template scanner never sees the `HTML` label as markup.
    def self.template_content_range(method_node : Node) : Tuple(Int32, Int32)?
      string_node = string_node_from_method_node(method_node)
      return nil unless string_node

      content_range(string_node)
    end

    # Returns the literal content range plus whether Ruby treats backslash
    # sequences as escapes. Lint uses raw bytes for source ranges and decodes
    # only its scanner copy, so escaped quotes cannot hide later placeholders.
    def self.template_content_info(method_node : Node) : Tuple(Int32, Int32, Bool)?
      string_node = string_node_from_method_node(method_node)
      return nil unless string_node
      range = content_range(string_node)
      return nil unless range

      {range[0], range[1], single_quoted_literal?(method_node, string_node)}
    end

    # Returns the byte range of the literal's contents (without Ruby quote or
    # percent delimiters) in the original source. Callers use this to map
    # template spans back to the user's file.
    def self.string_source_range(method_node : Node) : Tuple(Int32, Int32)?
      string_node = string_node_from_method_node(method_node)
      return nil unless string_node

      content_range(string_node)
    end

    private def self.content_range(string_node : Node) : Tuple(Int32, Int32)?
      text = string_node.text
      start_byte = string_node.start_byte
      end_byte = string_node.end_byte

      if text.starts_with?("%Q") || text.starts_with?("%q")
        return nil if text.bytesize < 4
        delimiter = text.byte_at(2)
        closing = case delimiter
                  when 123_u8 then 125_u8
                  when  91_u8 then 93_u8
                  when  40_u8 then 41_u8
                  when  60_u8 then 62_u8
                  else             delimiter
                  end
        return {start_byte + 3, end_byte - 1} if text.byte_at(text.bytesize - 1) == closing
      elsif text.starts_with?("%") && text.bytesize >= 3 && bare_percent_literal?(text)
        delimiter = text.byte_at(1)
        closing = case delimiter
                  when 123_u8 then 125_u8
                  when  91_u8 then 93_u8
                  when  40_u8 then 41_u8
                  when  60_u8 then 62_u8
                  else             delimiter
                  end
        return {start_byte + 2, end_byte - 1} if text.byte_at(text.bytesize - 1) == closing
      elsif text.starts_with?('"') || text.starts_with?('\'')
        return {start_byte + 1, end_byte - 1}
      elsif string_node.type.starts_with?("heredoc")
        content = first_heredoc_content(string_node)
        return {content.start_byte, content.end_byte} if content
      end

      nil
    end

    private def self.bare_percent_literal?(text : String) : Bool
      delimiter = text.byte_at(1)
      return false if (65_u8 <= delimiter <= 90_u8) || (97_u8 <= delimiter <= 122_u8)
      return false if (48_u8 <= delimiter <= 57_u8) || delimiter == 32_u8
      true
    end

    private def self.single_quoted_literal?(method_node : Node, string_node : Node) : Bool
      text = string_node.text
      return true if text.starts_with?("'") || text.starts_with?("%q")
      return false unless string_node.type.starts_with?("heredoc")

      heredoc_beginning(method_node).try(&.text.includes?("'")) || false
    end

    private def self.heredoc_beginning(node : Node) : Node?
      return node if node.type == "heredoc_beginning"

      node.each_named_child do |child|
        if found = heredoc_beginning(child)
          return found
        end
      end
      nil
    end

    private def self.first_heredoc_content(node : Node) : Node?
      return node if node.type == "heredoc_content"

      node.each_named_child do |child|
        if content = first_heredoc_content(child)
          return content
        end
      end

      nil
    end

    private def self.find_method_node(node : Node) : Node?
      return node if node.type == "method"

      node.each_named_child do |child|
        if result = find_method_node(child)
          return result
        end
      end

      nil
    end

    private def self.find_string_in_body(body_node : Node) : Node?
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
          if found = find_first_string_node(first_child)
            return found
          end
        when "call"
          receiver = first_child.child_by_field_name("receiver")
          if receiver
            if found = find_first_string_node(receiver)
              return found
            end
          end
        end
      end

      return find_first_string_node(body_node)
    end

    private def self.find_first_string_node(node : Node) : Node?
      return node if node.type == "string" || node.type.in?("heredoc_body", "heredoc_content")

      node.each_named_child do |child|
        if result = find_first_string_node(child)
          return result
        end
      end

      return nil
    end

    private def self.extract_string_content(string_node : Node) : String
      case string_node.type
      when "string"
        return extract_regular_string_content(string_node)
      when "heredoc_body"
        return string_node.text
      when "array"
        return string_node.text
      else
        return string_node.text
      end
    end

    private def self.extract_regular_string_content(string_node : Node) : String
      full_text = string_node.text
      is_percent_string = full_text.starts_with?("%Q{") || full_text.starts_with?("%q{")

      content_parts = [] of String

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
        return normalize_whitespace(result.strip)
      else
        return result
      end
    end

    private def self.normalize_whitespace(text : String) : String
      return text.gsub("  ", " ")
    end

    private def self.strip_quote_delimiters(text : String) : String
      if text.starts_with?("%Q{") && text.ends_with?("}")
        return normalize_whitespace(text[3...-1].strip)
      elsif text.starts_with?("%q{") && text.ends_with?("}")
        return normalize_whitespace(text[3...-1].strip)
      elsif text.starts_with?('"') && text.ends_with?('"')
        return text[1...-1]
      elsif text.starts_with?("'") && text.ends_with?("'")
        return text[1...-1]
      end

      return text
    end

    private def self.extract_from_fallback(body : Array(String)) : String
      return "" if body.size < 2

      inner_body = body[1...body.size - 1]
        .join("\n")
        .strip

      if inner_body.starts_with?("%Q{") && inner_body.ends_with?("}")
        return normalize_whitespace(inner_body[3...-1].strip)
      elsif inner_body.starts_with?("%q{") && inner_body.ends_with?("}")
        return normalize_whitespace(inner_body[3...-1].strip)
      elsif inner_body.starts_with?('"') && inner_body.ends_with?('"')
        return inner_body[1...-1]
      elsif inner_body.starts_with?("'") && inner_body.ends_with?("'")
        return inner_body[1...-1]
      end

      return inner_body
    end
  end
end
