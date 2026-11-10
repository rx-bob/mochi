class SorbetTypeStripper
  SIG_TOKEN        = "sig"
  TYPE_ALIAS_TOKEN = "T.type_alias"

  def self.strip(source : String) : String
    code = remove_magic_comments_and_sig_extends(source)
    code = remove_braced_statements(code, SIG_TOKEN)
    code = remove_braced_statements(code, TYPE_ALIAS_TOKEN)
    code = remove_type_alias_assignments(code)
    transform_calls(code)
  end

  private def self.remove_magic_comments_and_sig_extends(source : String) : String
    lines = source.split("\n", remove_empty: false)
    lines.map! do |line|
      stripped = line.strip
      if stripped.match(/^#\s*typed:\s*\w+/)
        ""
      elsif stripped == "extend T::Sig" || stripped.starts_with?("extend T::Sig #")
        ""
      elsif stripped == "include T::Sig" || stripped.starts_with?("include T::Sig #")
        ""
      else
        line
      end
    end
    lines.join("\n")
  end

  private def self.remove_braced_statements(source : String, token : String) : String
    out = String::Builder.new
    index = 0

    while index < source.size
      if literal_end = skip_literal_or_comment(source, index)
        out << source[index...literal_end]
        index = literal_end
        next
      end

      if token_at?(source, index, token)
        open_index = next_non_whitespace(source, index + token.size)
        if open_index && source[open_index] == '{'
          close_index = find_matching(source, open_index, '{', '}')
          if close_index
            out << blank_span(source[index..close_index])
            index = close_index + 1
            next
          end
        elsif (token == SIG_TOKEN || token == TYPE_ALIAS_TOKEN) && open_index && token_at?(source, open_index, "do")
          close_index = find_matching_do_block(source, open_index)
          if close_index
            out << blank_span(source[index..close_index])
            index = close_index + 1
            next
          end
        end
      end

      out << source[index]
      index += 1
    end

    out.to_s
  end

  private def self.remove_type_alias_assignments(source : String) : String
    out = String::Builder.new
    index = 0

    while index < source.size
      if literal_end = skip_literal_or_comment(source, index)
        out << source[index...literal_end]
        index = literal_end
        next
      end

      if token_at?(source, index, TYPE_ALIAS_TOKEN)
        open_index = next_non_whitespace(source, index + TYPE_ALIAS_TOKEN.size)
        if open_index
          if source[open_index] == '('
            close_index = find_matching(source, open_index, '(', ')')
            if close_index
              out << blank_span(source[index..close_index])
              index = close_index + 1
              next
            end
          elsif source[open_index] == '='
            line_end = source.index('\n', open_index) || source.size
            out << blank_span(source[index...line_end])
            index = line_end
            next
          end
        end
      end

      out << source[index]
      index += 1
    end

    out.to_s
  end

  private def self.transform_calls(source : String) : String
    out = String::Builder.new
    index = 0

    while index < source.size
      if literal_end = skip_literal_or_comment(source, index)
        out << source[index...literal_end]
        index = literal_end
        next
      end

      transformed = nil

      if token_at?(source, index, "T.let")
        transformed = transform_first_argument(source, index, "T.let")
      elsif token_at?(source, index, "T.must")
        transformed = transform_first_argument(source, index, "T.must")
      elsif token_at?(source, index, "T.cast")
        transformed = transform_first_argument(source, index, "T.cast")
      elsif token_at?(source, index, "T.unsafe")
        transformed = transform_first_argument(source, index, "T.unsafe")
      elsif token_at?(source, index, "T.reveal_type")
        transformed = transform_first_argument(source, index, "T.reveal_type")
      elsif token_at?(source, index, "T.absurd")
        transformed = transform_first_argument(source, index, "T.absurd")
      elsif token_at?(source, index, "T::Array")
        transformed = transform_type_constant(source, index, "T::Array", "Array")
      elsif token_at?(source, index, "T::Hash")
        transformed = transform_type_constant(source, index, "T::Hash", "Hash")
      elsif token_at?(source, index, "T::Boolean")
        transformed = {"TrueClass", index + "T::Boolean".size}
      end

      if transformed
        replacement, next_index = transformed
        out << replacement
        index = next_index
      else
        out << source[index]
        index += 1
      end
    end

    out.to_s
  end

  private def self.transform_first_argument(source : String, index : Int32, token : String) : Tuple(String, Int32)?
    open_index = next_non_whitespace(source, index + token.size)
    return nil unless open_index && source[open_index] == '('

    close_index = find_matching(source, open_index, '(', ')')
    return nil unless close_index

    inner = source[(open_index + 1)...close_index]
    first_argument = first_argument(inner)
    replacement = transform_calls(first_argument.strip)
    replacement = preserve_newlines(source[index..close_index], replacement)

    {replacement, close_index + 1}
  end

  private def self.transform_type_constant(source : String, index : Int32, token : String, replacement : String) : Tuple(String, Int32)?
    open_index = next_non_whitespace(source, index + token.size)
    return nil unless open_index && source[open_index] == '['

    close_index = find_matching(source, open_index, '[', ']')
    return nil unless close_index

    value = preserve_newlines(source[index..close_index], replacement)

    {value, close_index + 1}
  end

  private def self.first_argument(inner : String) : String
    depth = 0
    index = 0

    while index < inner.size
      if literal_end = skip_literal_or_comment(inner, index)
        index = literal_end
        next
      end

      case inner[index]
      when '(', '[', '{'
        depth += 1
      when ')', ']', '}'
        depth -= 1 if depth > 0
      when ','
        return inner[0...index] if depth == 0
      end

      index += 1
    end

    inner
  end

  private def self.find_matching(source : String, open_index : Int32, open_char : Char, close_char : Char) : Int32?
    depth = 0
    index = open_index

    while index < source.size
      if literal_end = skip_literal_or_comment(source, index)
        index = literal_end
        next
      end

      char = source[index]
      if char == open_char
        depth += 1
      elsif char == close_char
        depth -= 1
        return index if depth == 0
      end

      index += 1
    end

    nil
  end

  private def self.find_matching_do_block(source : String, do_index : Int32) : Int32?
    depth = 1
    index = do_index + 2

    while index < source.size
      if literal_end = skip_literal_or_comment(source, index)
        index = literal_end
        next
      end

      if token_at?(source, index, "do")
        depth += 1
        index += 2
        next
      elsif token_at?(source, index, "end")
        depth -= 1
        return index + 3 if depth == 0
        index += 3
        next
      end

      index += 1
    end

    nil
  end

  private def self.skip_literal_or_comment(source : String, index : Int32) : Int32?
    char = source[index]

    case char
    when '"', '\'', '`'
      cursor = index + 1
      while cursor < source.size
        current = source[cursor]
        if current == '\\'
          cursor += 2
        elsif current == char
          return cursor + 1
        else
          cursor += 1
        end
      end
      source.size
    when '#'
      newline = source.index('\n', index)
      newline || source.size
    else
      nil
    end
  end

  private def self.token_at?(source : String, index : Int32, token : String) : Bool
    return false unless source[index, token.size]? == token

    before = index == 0 ? '\0' : source[index - 1]
    after_index = index + token.size
    after = after_index < source.size ? source[after_index] : '\0'

    !word_char?(before) && !word_char?(after)
  end

  private def self.word_char?(char : Char) : Bool
    char.letter? || char.number? || char == '_'
  end

  private def self.next_non_whitespace(source : String, index : Int32) : Int32?
    cursor = index
    while cursor < source.size
      return cursor unless source[cursor].whitespace?
      cursor += 1
    end
    nil
  end

  private def self.blank_span(span : String) : String
    String.build do |builder|
      span.each_char do |char|
        builder << (char == '\n' ? '\n' : ' ')
      end
    end
  end

  private def self.preserve_newlines(original : String, replacement : String) : String
    missing = original.count('\n') - replacement.count('\n')
    return replacement if missing <= 0

    replacement + ("\n" * missing)
  end
end

module Sorbet
  alias TypeStripper = SorbetTypeStripper
end
