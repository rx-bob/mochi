require "big"
require "html"
require "json"
require "set"

require "../../html/template_expression"
require "../diagnostic"
require "../project_index"
require "../template_elements"

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
        Lint::TemplateElements.scan(view.text, parser).elements.each do |element|
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
      element : Lint::TemplateElements::Element,
      child : ClassInfo,
      parser : TemplateExpressionParser,
      issues : Array(SourceIssue),
    ) : Nil
      attributes = {} of String => Lint::TemplateElements::Attribute
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
  end
end
