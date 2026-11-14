require "../html/conditional_processor"
require "./inject_utils"
require "../html/attribute_conditional_extractor"
require "../html/each_row_template"
require "html"

class AttributeMethodGenerator
  METHOD_PREFIX   = "__mochi_attr_cond_"
  END_KEYWORD     = "end"
  FALLBACK_OFFSET = 3

  def self.inject_methods_into_class(ruby_code : String, class_name : String, conditionals : Array(ExtractedAttributeConditional)) : String
    return ruby_code if conditionals.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    methods_code = generate_all_methods(conditionals)
    return InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
  end

  def self.generate_all_methods(conditionals : Array(ExtractedAttributeConditional)) : String
    conditionals.map { |cond|
      generate_method(cond)
    }.join("\n")
  end

  def self.generate_method(
    cond : ExtractedAttributeConditional,
    method_name : String = "#{METHOD_PREFIX}#{cond.id}",
    scope : Array(EachRowScope) = [] of EachRowScope,
  ) : String
    attr_string = cond.original_string

    blocks = ConditionalProcessor.extract_conditionals(attr_string)
    blocks.sort_by! { |b| b.start_pos }

    # Build the attribute from string parts and join once. `_res += "text"`
    # compiles to OP_ADD, which the GVM only implements for integers; pushing
    # onto an array and joining keeps attribute conditionals executable while
    # preserving strict `{@ivar}` / `{method}` interpolation inside each part.
    body = "    _parts = []\n"

    last_pos = 0
    blocks.each do |block|
      if block.start_pos > last_pos
        text = attr_string[last_pos...block.start_pos]
        body += "    _parts << \"#{escape_and_interpolate(text)}\"\n"
      end

      block.branches.each_with_index do |branch, index|
        if index == 0
          body += "    if #{branch.condition}\n"
        elsif branch.condition
          body += "    elsif #{branch.condition}\n"
        else
          body += "    else\n"
        end
        body += "      _parts << \"#{escape_and_interpolate(branch.content)}\"\n"
      end
      body += "    end\n"

      last_pos = block.end_pos
    end

    if last_pos < attr_string.size
      text = attr_string[last_pos..-1]
      body += "    _parts << \"#{escape_and_interpolate(text)}\"\n"
    end

    body += "    _parts.join\n"

    params = [] of String
    assignments = [] of String
    scope.each_with_index do |entry, depth|
      item_param = "__mochi_scope_#{depth}_item"
      index_param = "__mochi_scope_#{depth}_index"
      params << item_param << index_param
      assignments << "    #{entry.item_name} = #{item_param}"
      assignments << "    #{entry.index_name} = #{index_param}" unless entry.index_name == entry.item_name
      unless entry.index_name == "index" || entry.item_name == "index"
        assignments << "    index = #{index_param}"
      end
    end
    prelude = assignments.join("\n")
    signature = params.join(", ")

    <<-RUBY

  # auto-generated attribute conditional method
  def #{method_name}(#{signature})
#{prelude}
#{body}  end

RUBY
  end

  # Convert `{var}` to `\#{var}` or `\#{@var}` to allow Ruby interpolation
  private def self.escape_and_interpolate(text : String) : String
    escaped = TemplateExpressionParser.escape_literal_braces(text)
    String.build do |io|
      cursor = 0
      TemplateExpressionParser.new.scan(escaped, "attribute").each do |expression|
        io << literal_part(escaped.byte_slice(cursor, expression.template_start - cursor))
        io << "\#{" << expression.source << "}"
        cursor = expression.template_end
      end
      io << literal_part(escaped.byte_slice(cursor))
    end
  end

  private def self.literal_part(text : String) : String
    HTML.unescape(text.gsub('\u{E000}', "{").gsub('\u{E001}', "}")).inspect[1...-1]
  end
end
