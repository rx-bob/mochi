require "html"
require "set"

require "../../html/template_expression"
require "../diagnostic"
require "../project_index"
require "../template_elements"

module Lint::Rules
  # Conservative template accessibility checks. Rules only report controls
  # whose authored markup proves the omission: dynamic text, dynamic
  # attributes, component children, and unresolved ARIA references stay
  # unknown rather than being treated as absent.
  module Accessibility
    CONTROL_NAME        = "accessibility/control-name"
    KEYBOARD_ACTIVATION = "accessibility/keyboard-activation"

    HTML_TAGS = Set{
      "a", "abbr", "address", "area", "article", "aside", "audio", "b", "base",
      "bdi", "bdo", "blockquote", "body", "br", "button", "canvas", "caption",
      "cite", "code", "col", "colgroup", "data", "datalist", "dd", "del",
      "details", "dfn", "dialog", "div", "dl", "dt", "em", "embed", "fieldset",
      "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
      "h6", "head", "header", "hgroup", "hr", "html", "i", "iframe", "img",
      "input", "ins", "kbd", "label", "legend", "li", "link", "main", "map",
      "mark", "menu", "meta", "meter", "nav", "noscript", "object", "ol",
      "optgroup", "option", "output", "p", "param", "picture", "pre",
      "progress", "q", "rp", "rt", "ruby", "s", "samp", "script", "section",
      "select", "slot", "small", "source", "span", "strong", "style", "sub",
      "summary", "sup", "table", "tbody", "td", "template", "textarea",
      "tfoot", "th", "thead", "time", "title", "tr", "track", "u", "ul", "var",
      "video", "wbr",
    }

    NON_CONTENT_TAGS = Set{
      "area", "base", "br", "canvas", "embed", "hr", "iframe", "input", "link",
      "meta", "object", "param", "picture", "script", "select", "source",
      "style", "template", "textarea", "title", "track", "video", "audio",
      "wbr",
    }

    NATIVE_FORM_TAGS = Set{"button", "input", "select", "textarea"}

    INERT_CONTAINER_TAGS = Set{
      "clippath", "defs", "filter", "lineargradient", "marker", "mask",
      "pattern", "radialgradient", "script", "style", "symbol", "template",
    }

    enum NameStatus
      Empty
      Named
      Unknown
    end

    enum Visibility
      Visible
      Hidden
      Unknown
    end

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      control_name = index.config.enabled?(CONTROL_NAME)
      keyboard_activation = index.config.enabled?(KEYBOARD_ACTIVATION)
      return [] of Diagnostic unless control_name || keyboard_activation

      issues = [] of SourceIssue
      index.target_templates.each do |view|
        audit = Audit.new(view)
        issues.concat(audit.control_name_issues) if control_name
        issues.concat(audit.keyboard_issues) if keyboard_activation
      end

      diagnostics = issues.compact_map do |issue|
        severity = index.config.severity_for(issue.rule)
        severity ? issue.diagnostic(severity) : nil
      end
      Diagnostics.sort(diagnostics)
    end

    private class Audit
      @view : TemplateView
      @parser : TemplateExpressionParser
      @document : Lint::TemplateElements::Document
      @by_id = {} of String => Lint::TemplateElements::Element
      @visibility = {} of UInt64 => Visibility

      def initialize(@view : TemplateView)
        @parser = TemplateExpressionParser.new
        @document = @view.elements
        @document.elements.each do |element|
          attribute = element.attribute("id")
          next unless attribute
          next if attribute.bare

          value = attribute_text(attribute)
          next if dynamic_value?(value)

          id = value.strip
          @by_id[id] ||= element unless id.empty?
        end
      end

      def control_name_issues : Array(SourceIssue)
        issues = [] of SourceIssue
        @document.elements.each do |element|
          next unless control_name_applicable?(element)
          next if inert_container?(element)
          next unless visibility(element) == Visibility::Visible
          next unless name_status(element) == NameStatus::Empty

          range = @view.source_range(element.name_start, element.name_end)
          issues << SourceIssue.new(
            @view.unit_path,
            @view.map,
            range.start_byte,
            range.end_byte,
            "#{control_description(element)} has no accessible name",
            CONTROL_NAME,
            "add visible text, aria-label, aria-labelledby, or an image alt value",
          )
        end
        issues
      end

      def keyboard_issues : Array(SourceIssue)
        issues = [] of SourceIssue
        @document.elements.each do |element|
          next unless role_button?(element)
          next if native_interactive?(element)
          next if inert_container?(element)
          next unless click_handler?(element)
          next if key_handler?(element)
          next unless visibility(element) == Visibility::Visible
          next if element.dynamic_attributes?

          range = @view.source_range(element.name_start, element.name_end)
          issues << SourceIssue.new(
            @view.unit_path,
            @view.map,
            range.start_byte,
            range.end_byte,
            "<#{element.tag} role=\"button\"> handles onclick but has no local onkeydown or onkeyup handler",
            KEYBOARD_ACTIVATION,
            "use a native <button> or add onkeydown/onkeyup on the same element",
          )
        end
        issues
      end

      private def control_name_applicable?(element : Lint::TemplateElements::Element) : Bool
        return true if element.tag == "button"
        return true if element.tag == "a" && element.attribute("href")
        return false if NATIVE_FORM_TAGS.includes?(element.tag)

        role_state(element) == true
      end

      private def inert_container?(element : Lint::TemplateElements::Element) : Bool
        return true if INERT_CONTAINER_TAGS.includes?(element.tag)

        current = element.parent
        while current
          return true if INERT_CONTAINER_TAGS.includes?(current.tag)
          current = current.parent
        end
        false
      end

      private def native_interactive?(element : Lint::TemplateElements::Element) : Bool
        case element.tag
        when "button", "input", "select", "textarea", "summary"
          true
        when "a"
          !element.attribute("href").nil?
        else
          false
        end
      end

      private def control_description(element : Lint::TemplateElements::Element) : String
        if element.tag == "button"
          "<button>"
        elsif element.tag == "a" && element.attribute("href")
          "<a href>"
        else
          "<#{element.tag} role=\"button\">"
        end
      end

      private def role_button?(element : Lint::TemplateElements::Element) : Bool
        role_state(element) == true
      end

      private def role_state(element : Lint::TemplateElements::Element) : Bool?
        attribute = element.attribute("role")
        return nil unless attribute
        return nil if attribute.bare

        value = attribute_text(attribute)
        return nil if dynamic_value?(value)

        value.downcase.split.includes?("button")
      end

      private def click_handler?(element : Lint::TemplateElements::Element) : Bool
        element.attributes.any? { |attribute| event_attribute?(attribute.name, "onclick") }
      end

      private def key_handler?(element : Lint::TemplateElements::Element) : Bool
        element.attributes.any? do |attribute|
          event_attribute?(attribute.name, "onkeydown") || event_attribute?(attribute.name, "onkeyup")
        end
      end

      private def event_attribute?(name : String, event : String) : Bool
        normalized = name.downcase
        normalized == event || normalized.starts_with?("#{event}.")
      end

      private def name_status(
        element : Lint::TemplateElements::Element,
        visited : Set(UInt64) = Set(UInt64).new,
        ignore_visibility : Bool = false,
      ) : NameStatus
        unless ignore_visibility
          case visibility(element)
          when Visibility::Hidden
            return NameStatus::Empty
          when Visibility::Unknown
            return NameStatus::Unknown
          end
        end

        return NameStatus::Unknown if visited.includes?(element.object_id)
        next_visited = visited.dup
        next_visited << element.object_id

        if attribute = element.attribute("aria-label")
          return NameStatus::Unknown if attribute.bare

          value = attribute_text(attribute)
          return NameStatus::Unknown if dynamic_value?(value)
          return NameStatus::Named unless value.strip.empty?
        end

        if attribute = element.attribute("aria-labelledby")
          return NameStatus::Unknown if attribute.bare

          value = attribute_text(attribute)
          return NameStatus::Unknown if dynamic_value?(value)

          unresolved = false
          value.split.each do |id|
            target = @by_id[id]?
            if target
              case name_status(target, next_visited, ignore_visibility: true)
              when NameStatus::Named
                return NameStatus::Named
              when NameStatus::Unknown
                unresolved = true
              end
            else
              unresolved = true
            end
          end
          return NameStatus::Unknown if unresolved
        end

        return image_status(element) if element.tag == "img"
        return svg_name_status(element, next_visited) if element.tag == "svg"

        named = false
        unknown = false

        element.text_segments.each do |segment|
          named = true unless text_value(segment).strip.empty?
        end
        unknown = true if element.dynamic_content

        element.children.each do |child|
          case child_status(child, next_visited)
          when NameStatus::Named
            named = true
          when NameStatus::Unknown
            unknown = true
          end
        end

        return NameStatus::Named if named
        return NameStatus::Unknown if unknown || element.dynamic_attributes?

        NameStatus::Empty
      end

      private def svg_name_status(
        element : Lint::TemplateElements::Element,
        visited : Set(UInt64),
      ) : NameStatus
        title = element.children.find { |child| child.tag == "title" }
        return NameStatus::Empty unless title

        title_status(title, visited)
      end

      private def title_status(
        element : Lint::TemplateElements::Element,
        visited : Set(UInt64),
      ) : NameStatus
        return NameStatus::Unknown if element.dynamic_content
        element.text_segments.each do |segment|
          return NameStatus::Named unless text_value(segment).strip.empty?
        end
        element.children.each do |child|
          return NameStatus::Unknown unless child.tag == "br"
        end
        NameStatus::Empty
      end

      private def child_status(
        element : Lint::TemplateElements::Element,
        visited : Set(UInt64),
      ) : NameStatus
        case visibility(element)
        when Visibility::Hidden
          return NameStatus::Empty
        when Visibility::Unknown
          return NameStatus::Unknown
        end

        case element.tag
        when "img"
          image_status(element)
        when "svg"
          name_status(element, visited)
        when "slot"
          NameStatus::Unknown
        else
          if element.tag.includes?('-') || !HTML_TAGS.includes?(element.tag)
            NameStatus::Unknown
          elsif NON_CONTENT_TAGS.includes?(element.tag)
            NameStatus::Empty
          else
            name_status(element, visited)
          end
        end
      end

      private def image_status(element : Lint::TemplateElements::Element) : NameStatus
        attribute = element.attribute("alt")
        return NameStatus::Empty unless attribute
        return NameStatus::Empty if attribute.bare

        value = attribute_text(attribute)
        return NameStatus::Unknown if dynamic_value?(value)
        value.strip.empty? ? NameStatus::Empty : NameStatus::Named
      end

      private def visibility(element : Lint::TemplateElements::Element) : Visibility
        key = element.object_id
        if cached = @visibility[key]?
          return cached
        end

        parent_state = element.parent ? visibility(element.parent.not_nil!) : Visibility::Visible
        result = if parent_state == Visibility::Hidden
                   Visibility::Hidden
                 else
                   own = own_visibility(element)
                   if own == Visibility::Hidden
                     Visibility::Hidden
                   elsif own == Visibility::Unknown || parent_state == Visibility::Unknown
                     Visibility::Unknown
                   else
                     Visibility::Visible
                   end
                 end

        @visibility[key] = result
        result
      end

      private def own_visibility(element : Lint::TemplateElements::Element) : Visibility
        hidden = hidden_attribute(element)
        return Visibility::Hidden if hidden == Visibility::Hidden
        return Visibility::Unknown if hidden == Visibility::Unknown

        aria_hidden = aria_hidden_attribute(element)
        return Visibility::Hidden if aria_hidden == Visibility::Hidden
        return Visibility::Unknown if aria_hidden == Visibility::Unknown

        inert = inert_attribute(element)
        return Visibility::Hidden if inert == Visibility::Hidden
        return Visibility::Unknown if inert == Visibility::Unknown

        Visibility::Visible
      end

      private def hidden_attribute(element : Lint::TemplateElements::Element) : Visibility
        boolean_hidden_attribute(element, "hidden")
      end

      private def inert_attribute(element : Lint::TemplateElements::Element) : Visibility
        boolean_hidden_attribute(element, "inert")
      end

      private def boolean_hidden_attribute(
        element : Lint::TemplateElements::Element,
        name : String,
      ) : Visibility
        attribute = element.attribute(name)
        return Visibility::Visible unless attribute
        return Visibility::Hidden if attribute.bare

        value = attribute_text(attribute)
        return Visibility::Unknown if dynamic_value?(value)

        value.strip.downcase == "false" ? Visibility::Visible : Visibility::Hidden
      end

      private def aria_hidden_attribute(element : Lint::TemplateElements::Element) : Visibility
        attribute = element.attribute("aria-hidden")
        return Visibility::Visible unless attribute
        return Visibility::Unknown if attribute.bare

        value = attribute_text(attribute)
        return Visibility::Unknown if dynamic_value?(value)

        value.strip.downcase == "true" ? Visibility::Hidden : Visibility::Visible
      end

      private def dynamic_value?(value : String) : Bool
        !@parser.scan(value, "attribute", validate: false).empty?
      rescue TemplateExpressionError
        true
      end

      private def attribute_text(attribute : Lint::TemplateElements::Attribute) : String
        HTML.unescape(@view.text.byte_slice(attribute.value_start, attribute.value_end - attribute.value_start))
      end

      private def text_value(segment : Lint::TemplateElements::TextSegment) : String
        HTML.unescape(@view.text.byte_slice(segment.start, segment.finish - segment.start))
      end
    end
  end
end
