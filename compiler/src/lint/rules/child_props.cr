require "big"
require "html"
require "json"
require "set"

require "../../html/template_expression"
require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Checks statically known child component tags against declared prop
  # contracts. Only literal attribute text is judged: parent bindings,
  # conditional values, and attribute hashes stay statically unknown, and a
  # required prop is never called missing when a spread could supply it.
  module ChildProps
    CHILD_PROPS      = "correctness/child-props"
    INTEGER_TEXT     = /\A-?\d+\z/
    FLOAT_TEXT       = /\A-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\z/
    SPECIAL_FLOATS   = Set{"Infinity", "-Infinity", "NaN"}
    MAX_SAFE_INTEGER = 9_007_199_254_740_991_i64

    record ElementAttribute,
      name : String,
      start : Int32,
      finish : Int32,
      name_start : Int32,
      name_end : Int32,
      value_start : Int32,
      value_end : Int32,
      bare : Bool

    record ChildElement,
      tag : String,
      start_byte : Int32,
      name_start : Int32,
      name_end : Int32,
      finish : Int32,
      attributes : Array(ElementAttribute),
      dynamic_attributes : Bool

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      return [] of Diagnostic unless index.config.enabled?(CHILD_PROPS)

      issues = child_prop_issues(index)
      diagnostics = issues.compact_map do |issue|
        severity = index.config.severity_for(issue.rule)
        severity ? issue.diagnostic(severity) : nil
      end
      Diagnostics.sort(diagnostics)
    end

    private def self.child_prop_issues(index : ProjectIndex) : Array(SourceIssue)
      issues = [] of SourceIssue
      parser = TemplateExpressionParser.new

      index.target_templates.each do |view|
        scan_elements(view.text, parser).each do |element|
          child = index.tags[element.tag]?
          next unless child
          next if child.props.empty?

          check_element(view, element, child, parser, issues)
        end
      end

      issues
    end

    private def self.check_element(
      view : TemplateView,
      element : ChildElement,
      child : ClassInfo,
      parser : TemplateExpressionParser,
      issues : Array(SourceIssue),
    ) : Nil
      attributes = {} of String => ElementAttribute
      element.attributes.each do |attribute|
        attributes[prop_name(attribute.name)] = attribute
      end

      child.props.each do |prop|
        attribute = attributes[prop.name]?
        if attribute.nil?
          next if element.dynamic_attributes
          next unless prop.required

          range = view.source_range(element.name_start, element.name_end)
          issues << SourceIssue.new(
            view.unit_path,
            view.map,
            range.start_byte,
            range.end_byte,
            "required prop '#{prop.name}' is missing on <#{element.tag}> " \
            "(declared as #{prop.type_name} at #{declaration_location(child, prop)})",
            CHILD_PROPS,
            "pass #{prop.name.gsub('_', '-')}=\"...\" on <#{element.tag}> or declare a default for '#{prop.name}'",
          )
          next
        end

        # The browser decodes HTML entities once before the loader validates
        # the attribute text, so lint judges the same decoded literal.
        value = HTML.unescape(view.text.byte_slice(attribute.value_start, attribute.value_end - attribute.value_start))
        # `bind:<attr>` is rewritten into a bound attribute before the loader
        # sees it, so its value is supplied but statically unknown here.
        next if attribute.name.downcase.starts_with?("bind:")

        problem = literal_problem(prop, value, attribute.bare, parser)
        next unless problem

        issue_start = attribute.bare || value.empty? ? attribute.name_start : attribute.start
        range = view.source_range(issue_start, attribute.finish)
        issues << SourceIssue.new(
          view.unit_path,
          view.map,
          range.start_byte,
          range.end_byte,
          "prop '#{prop.name}' on <#{element.tag}> #{problem} " \
          "(declared as #{prop.type_name} at #{declaration_location(child, prop)})",
          CHILD_PROPS,
          type_suggestion(prop),
        )
      end
    end

    private def self.prop_name(attribute_name : String) : String
      name = attribute_name.downcase
      name = name[5..] if name.starts_with?("bind:")
      name.gsub('-', '_')
    end

    private def self.declaration_location(child : ClassInfo, prop : TreeSitter::PropertyExtractor::PropDeclaration) : String
      path = child.path
      path.empty? ? "line #{prop.line}" : "#{path}:#{prop.line}"
    end

    private def self.type_suggestion(prop : TreeSitter::PropertyExtractor::PropDeclaration) : String
      case prop.type
      when "string"  then "pass any text for prop '#{prop.name}'"
      when "integer" then "use an integer text value inside the signed 64-bit range for prop '#{prop.name}'"
      when "float"   then "use a decimal, Infinity, -Infinity, or NaN text value for prop '#{prop.name}'"
      when "boolean" then "use 'true', 'false', or an empty attribute for prop '#{prop.name}'"
      when "array"   then "use JSON array text such as [1,2] for prop '#{prop.name}'"
      else                "use JSON object text such as {\"key\":1} for prop '#{prop.name}'"
      end
    end

    private def self.literal_problem(
      prop : TreeSitter::PropertyExtractor::PropDeclaration,
      value : String,
      bare : Bool,
      parser : TemplateExpressionParser,
    ) : String?
      case prop.type
      when "string"
        nil
      when "boolean"
        return nil if bare || value.empty?
        return nil if dynamic_text?(value, parser)
        return nil if value == "true" || value == "false"
        "expects a Boolean text value 'true', 'false', or an empty attribute, got #{value.inspect}"
      when "integer"
        return nil if dynamic_text?(value, parser)
        return "expects an Integer text value, got #{value.inspect}" unless INTEGER_TEXT.matches?(value)
        int64_text?(value) ? nil : "Integer #{value} is outside the signed 64-bit range"
      when "float"
        return nil if dynamic_text?(value, parser)
        return nil if SPECIAL_FLOATS.includes?(value) || FLOAT_TEXT.matches?(value)
        "expects a Float text value, got #{value.inspect}"
      when "array", "hash"
        collection_problem(prop, value, parser)
      else
        nil
      end
    end

    # The loader tries JSON first for collection props. A non-JSON value is
    # only a binding when it carries a template expression; otherwise it is an
    # authored literal and fails the contract.
    private def self.collection_problem(
      prop : TreeSitter::PropertyExtractor::PropDeclaration,
      value : String,
      parser : TemplateExpressionParser,
    ) : String?
      parsed = begin
        JSON.parse(value.strip)
      rescue JSON::ParseException
        return nil if dynamic_text?(value, parser)
        return "expects JSON #{prop.type} text, got #{value.inspect}"
      end

      case prop.type
      when "array"
        return "expects a JSON array, got #{value.inspect}" unless parsed.as_a?
      when "hash"
        return "expects a JSON object, got #{value.inspect}" unless parsed.as_h?
      end

      number_problem(parsed)
    end

    private def self.dynamic_text?(value : String, parser : TemplateExpressionParser) : Bool
      return true if value.includes?("{{")
      !parser.scan(value, "attribute", validate: false).empty?
    rescue TemplateExpressionError
      true
    end

    private def self.int64_text?(text : String) : Bool
      value = BigInt.new(text)
      value >= Int64::MIN && value <= Int64::MAX
    rescue
      false
    end

    private def self.number_problem(value : JSON::Any) : String?
      case raw = value.raw
      when Int64
        if raw > MAX_SAFE_INTEGER || raw < -MAX_SAFE_INTEGER
          return "contains an Integer outside JavaScript's exact number range"
        end
      when Float64
        return "contains a non-finite Float" unless raw.finite?
      when Array
        raw.each do |item|
          if problem = number_problem(item)
            return problem
          end
        end
      when Hash
        raw.each_value do |item|
          if problem = number_problem(item)
            return problem
          end
        end
      end
      nil
    end

    private def self.scan_elements(text : String, parser : TemplateExpressionParser) : Array(ChildElement)
      elements = [] of ChildElement
      index = 0

      while index < text.bytesize
        byte = text.byte_at(index)
        if byte == 123_u8
          index = skip_placeholder(text, index)
          next
        end

        unless byte == 60_u8
          index += 1
          next
        end

        if text.byte_slice(index, Math.min(4, text.bytesize - index)) == "<!--"
          ending = text.byte_index("-->", index)
          index = ending ? ending + 3 : text.bytesize
          next
        end

        if index + 1 >= text.bytesize
          index += 1
          next
        end

        next_byte = text.byte_at(index + 1)
        if next_byte == 47_u8
          index = skip_tag(text, index + 2)
          next
        end

        unless letter?(next_byte)
          index = next_byte == 33_u8 || next_byte == 63_u8 ? skip_tag(text, index + 2) : index + 1
          next
        end

        element, next_index = scan_element(text, index, parser)
        elements << element if element
        index = next_index
      end

      elements
    end

    private def self.scan_element(text : String, start : Int32, parser : TemplateExpressionParser) : Tuple(ChildElement?, Int32)
      index = start + 1
      name_start = index
      while index < text.bytesize && name_byte?(text.byte_at(index))
        index += 1
      end
      name_end = index
      tag = text.byte_slice(name_start, name_end - name_start).downcase

      attributes = [] of ElementAttribute
      dynamic_attributes = false
      finish = text.bytesize

      while index < text.bytesize
        index = skip_whitespace(text, index)
        break if index >= text.bytesize

        byte = text.byte_at(index)
        if byte == 62_u8
          finish = index + 1
          index = finish
          break
        end
        if byte == 47_u8 && index + 1 < text.bytesize && text.byte_at(index + 1) == 62_u8
          finish = index + 2
          index = finish
          break
        end
        if byte == 123_u8
          dynamic_attributes = true
          index = skip_placeholder(text, index)
          next
        end
        unless name_byte?(byte)
          index += 1
          next
        end

        attribute_start = index
        while index < text.bytesize && name_byte?(text.byte_at(index))
          index += 1
        end
        attribute_name_end = index
        attribute_name = text.byte_slice(attribute_start, attribute_name_end - attribute_start)
        index = skip_whitespace(text, index)

        value_start = index
        value_end = index
        bare = true

        if index < text.bytesize && text.byte_at(index) == 61_u8
          bare = false
          index += 1
          index = skip_whitespace(text, index)
          if index < text.bytesize && (text.byte_at(index) == 34_u8 || text.byte_at(index) == 39_u8)
            quote = text.byte_at(index)
            index += 1
            value_start = index
            closed = false
            while index < text.bytesize
              current = text.byte_at(index)
              if current == quote
                value_end = index
                index += 1
                closed = true
                break
              elsif current == 123_u8
                if close = TemplateExpressionParser.matching_brace(text, index)
                  dynamic_attributes = true if hash_spread?(text, index, close, quoted: true, parser: parser)
                  index = close + 1
                else
                  index += 1
                end
              else
                index += 1
              end
            end
            value_end = index unless closed
          else
            value_start = index
            while index < text.bytesize
              current = text.byte_at(index)
              break if whitespace?(current) || current == 62_u8
              break if current == 47_u8 && index + 1 < text.bytesize && text.byte_at(index + 1) == 62_u8
              if current == 123_u8
                if close = TemplateExpressionParser.matching_brace(text, index)
                  dynamic_attributes = true if hash_spread?(text, index, close, quoted: false, parser: parser)
                  index = close + 1
                else
                  index += 1
                end
              else
                index += 1
              end
            end
            value_end = index
          end
        end

        attributes << ElementAttribute.new(
          attribute_name,
          attribute_start,
          index,
          attribute_start,
          attribute_name_end,
          value_start,
          value_end,
          bare,
        )
      end

      {ChildElement.new(tag, start, name_start, name_end, finish, attributes, dynamic_attributes), index}
    end

    private def self.hash_spread?(
      text : String,
      index : Int32,
      close : Int32,
      quoted : Bool,
      parser : TemplateExpressionParser,
    ) : Bool
      return false unless index + 1 < text.bytesize && text.byte_at(index + 1) == 123_u8
      return true unless quoted
      token = text.byte_slice(index, close - index + 1)
      parser.hash_literal_intent?(token[1...-1])
    end

    private def self.skip_placeholder(text : String, index : Int32) : Int32
      if close = TemplateExpressionParser.matching_brace(text, index)
        close + 1
      else
        index + 1
      end
    end

    private def self.skip_tag(text : String, index : Int32) : Int32
      while index < text.bytesize
        return index + 1 if text.byte_at(index) == 62_u8
        index += 1
      end
      index
    end

    private def self.skip_whitespace(text : String, index : Int32) : Int32
      while index < text.bytesize && whitespace?(text.byte_at(index))
        index += 1
      end
      index
    end

    private def self.letter?(byte : UInt8) : Bool
      (65_u8 <= byte <= 90_u8) || (97_u8 <= byte <= 122_u8)
    end

    private def self.name_byte?(byte : UInt8) : Bool
      letter?(byte) || (48_u8 <= byte <= 57_u8) ||
        byte == 95_u8 || byte == 45_u8 || byte == 58_u8 || byte == 46_u8
    end

    private def self.whitespace?(byte : UInt8) : Bool
      byte == 32_u8 || byte == 9_u8 || byte == 10_u8 || byte == 13_u8 || byte == 12_u8
    end
  end
end
