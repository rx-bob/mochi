require "html"
require "set"

require "../../html/template_expression"
require "../../tree-sitter/string_extractor"
require "../diagnostic"
require "../project_index"
require "../template_elements"

module Lint::Rules
  # Opt-in migration advice for CSS animation loops used as timers. The
  # detector requires all evidence inside one component source: a native
  # animationend/animationiteration handler on a hidden driver element, a
  # directly authored callback that changes state used by that driver, and
  # another local state mutation or known nonvisual API call. Opaque helper
  # calls, visible animation completion handlers, and CSS imported from shared
  # fragments stay unreported because their behavior cannot be proven locally.
  module TimerAdvice
    RULE = "migration/css-timer"

    ANIMATION_EVENTS        = Set{"onanimationend", "onanimationiteration"}
    TIMER_METHODS           = Set{"after", "every"}
    HIDDEN_CLASSES          = Set{"hidden", "sr-only", "visually-hidden", "visuallyhidden", "screen-reader-only", "offscreen"}
    NONVISUAL_MOCHI_METHODS = Set{
      "emit",
      "storage_set",
      "storage_remove",
      "storage_subscribe",
      "navigate",
      "replace_route",
    }
    NONVISUAL_RECEIVERS = {
      "MochiStore"     => Set{"write", "clear"},
      "MochiDownload"  => Set{"save"},
      "MochiShortcuts" => Set{"register", "cancel"},
    }

    record HandlerEvidence,
      mutations : Set(String),
      restarts : Set(String),
      nonvisual_api : Bool,
      timer_api : Bool

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      return [] of Diagnostic unless index.config.enabled?(RULE)
      severity = index.config.severity_for(RULE)
      return [] of Diagnostic unless severity

      parser = TemplateExpressionParser.new
      css_cache = {} of String => String?
      seen = Set(Tuple(String, String, String)).new
      issues = [] of SourceIssue

      index.target_templates.each do |view|
        owner = index.class_info(view.owner_name)
        next unless owner && owner.component?
        css = css_cache.fetch(view.owner_name) do
          value = css_literal(index, owner)
          css_cache[view.owner_name] = value
          value
        end
        document = Lint::TemplateElements.scan(view.text, parser)

        document.elements.each do |element|
          event = animation_event(element)
          next unless event

          handler = event_handler(view, parser, event)
          next unless handler
          next unless hidden_element?(view, element, css, parser)

          method = owner.method(handler)
          next unless method && !method.singleton
          next unless method.unit_path == view.unit_path
          next unless index.selected.includes?(method.unit_path)
          body = method.body
          next unless body

          evidence = handler_evidence(body)
          next if evidence.timer_api

          driver_markup = view.text.byte_slice(element.start, element.finish - element.start)
          driver_state = evidence.restarts.select { |name| driver_markup.includes?("@#{name}") }
          next if driver_state.empty?

          repeated_work = evidence.mutations.any? { |name| !driver_state.includes?(name) } || evidence.nonvisual_api
          next unless repeated_work

          key = {view.unit_path, owner.qualified_name, handler}
          next if seen.includes?(key)
          seen << key

          range = view.source_range(event.name_start, event.name_end)
          issues << SourceIssue.new(
            view.unit_path,
            view.map,
            range.start_byte,
            range.end_byte,
            "hidden CSS animation callback '#{handler}' restarts a driver and repeats nonvisual work; use Mochi.every or Mochi.after with mount-owned cancellation; this is a review prompt, not proof that the loop is incorrect",
            RULE,
            "Use Mochi.every or Mochi.after with a zero-argument callback and mount-owned cancellation instead of a CSS animation timer; no manual JavaScript is needed.",
          )
        end
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end

    private def self.animation_event(element : Lint::TemplateElements::Element) : Lint::TemplateElements::Attribute?
      element.attributes.find do |attribute|
        ANIMATION_EVENTS.includes?(attribute.name.downcase.split('.', 2).first)
      end
    end

    private def self.event_handler(
      view : TemplateView,
      parser : TemplateExpressionParser,
      attribute : Lint::TemplateElements::Attribute,
    ) : String?
      value = attribute_value(view, attribute).strip
      return nil if value.empty?

      expressions = parser.scan(value, "event", validate: false)
      return nil unless expressions.size == 1
      expression = expressions.first
      return nil unless expression.full_text(value) == value

      method_name, _arguments = parser.parse_call(expression.source)
      if method_name.starts_with?("self.")
        method_name = method_name[5..]
      end
      return nil unless simple_method?(method_name)
      method_name
    rescue TemplateExpressionError
      nil
    end

    private def self.simple_method?(name : String) : Bool
      !name.empty? && name.matches?(/\A[a-z_][a-zA-Z0-9_]*[!?=]?\z/)
    end

    private def self.hidden_element?(
      view : TemplateView,
      element : Lint::TemplateElements::Element,
      css : String?,
      parser : TemplateExpressionParser,
    ) : Bool
      current = element
      while current
        return true if hidden_element_itself?(view, current, css, parser)
        current = current.parent
      end
      false
    end

    private def self.hidden_element_itself?(
      view : TemplateView,
      element : Lint::TemplateElements::Element,
      css : String?,
      parser : TemplateExpressionParser,
    ) : Bool
      return true if hidden_boolean_attribute?(view, element, "hidden", parser)
      return true if aria_hidden?(view, element, parser)
      return true if hidden_boolean_attribute?(view, element, "inert", parser)

      if style = element.attribute("style")
        return true if hidden_declarations?(attribute_value(view, style))
      end

      if classes = element.attribute("class")
        class_tokens(attribute_value(view, classes)).each do |token|
          return true if hidden_class_name?(token)
          return true if css && css_hides_class?(css, token)
        end
      end

      false
    end

    private def self.hidden_boolean_attribute?(
      view : TemplateView,
      element : Lint::TemplateElements::Element,
      name : String,
      parser : TemplateExpressionParser,
    ) : Bool
      attribute = element.attribute(name)
      return false unless attribute
      return true if attribute.bare

      value = attribute_value(view, attribute).strip
      return false if dynamic_value?(value, parser)
      value.downcase != "false"
    end

    private def self.aria_hidden?(
      view : TemplateView,
      element : Lint::TemplateElements::Element,
      parser : TemplateExpressionParser,
    ) : Bool
      attribute = element.attribute("aria-hidden")
      return false unless attribute
      return false if attribute.bare

      value = attribute_value(view, attribute).strip
      return false if dynamic_value?(value, parser)
      value.downcase == "true"
    end

    private def self.dynamic_value?(value : String, parser : TemplateExpressionParser) : Bool
      !parser.scan(value, "attribute", validate: false).empty?
    rescue TemplateExpressionError
      true
    end

    private def self.class_tokens(value : String) : Array(String)
      value.split(/\s+/).compact_map do |token|
        next nil if token.empty? || token.includes?('{') || token.includes?('}')
        token.downcase
      end
    end

    private def self.hidden_class_name?(token : String) : Bool
      HIDDEN_CLASSES.includes?(token) ||
        token.starts_with?("hidden-") ||
        token.ends_with?("-hidden") ||
        token.includes?("visually-hidden") ||
        token.includes?("screen-reader-only")
    end

    private def self.hidden_declarations?(text : String) : Bool
      text.split(';').each do |declaration|
        name, separator, value = declaration.partition(':')
        next if separator.empty?

        property = name.strip.downcase
        literal = value.strip.downcase
        next if literal.empty?

        case property
        when "visibility"
          return true if literal == "hidden"
        when "opacity"
          return true if literal.matches?(/\A0(?:\.0+)?\z/)
        when "width", "height"
          return true if literal.in?("0", "0px", "1px")
        when "overflow"
          return true if literal == "hidden"
        when "display"
          return true if literal == "none"
        when "font-size"
          return true if literal.in?("0", "0px")
        when "clip", "clip-path"
          return true
        when "transform"
          return true if literal.gsub(/\s+/, "").starts_with?("scale(0")
        when "left", "top"
          return true if literal.starts_with?("-")
        end
      end
      false
    end

    private def self.css_hides_class?(css : String, token : String) : Bool
      needle = ".#{token}"
      search = 0
      while index = css.index(needle, search)
        after = index + needle.bytesize
        boundary = after >= css.bytesize || !class_name_byte?(css.byte_at(after))
        if boundary
          if brace = css.index('{', after)
            if closing = css.index('}', brace + 1)
              body = css.byte_slice(brace + 1, closing - brace - 1)
              return true if hidden_declarations?(body)
            end
          end
        end
        search = index + 1
      end
      false
    end

    private def self.class_name_byte?(byte : UInt8) : Bool
      (48_u8 <= byte <= 57_u8) ||
        (65_u8 <= byte <= 90_u8) ||
        (97_u8 <= byte <= 122_u8) ||
        byte == 95_u8 || byte == 45_u8
    end

    private def self.css_literal(index : ProjectIndex, owner : ClassInfo) : String?
      method = owner.method("css")
      return nil unless method && !method.singleton
      unit = index.unit(method.unit_path)
      return nil unless unit
      range = TreeSitter::StringExtractor.template_content_info(method.node)
      return nil unless range
      unit.source.byte_slice(range[0], range[1] - range[0])
    end

    private def self.attribute_value(view : TemplateView, attribute : Lint::TemplateElements::Attribute) : String
      HTML.unescape(view.text.byte_slice(attribute.value_start, attribute.value_end - attribute.value_start))
    end

    private def self.handler_evidence(body : TreeSitter::Node) : HandlerEvidence
      mutations = Set(String).new
      restarts = Set(String).new
      mutation_counts = Hash(String, Int32).new(0)
      nonvisual_api = false
      timer_api = false

      visit_handler(body) do |node|
        case node.type
        when "assignment", "operator_assignment", "multiple_assignment"
          if left = node.child_by_field_name("left")
            names = mutation_names(left)
            names.each do |name|
              mutations << name
              mutation_counts[name] += 1
            end
            if node.type == "operator_assignment"
              names.each { |name| restarts << name }
            elsif right = node.child_by_field_name("right")
              mentioned = instance_variables(right)
              names.each { |name| restarts << name if mentioned.includes?(name) }
            end
          end
        when "binary"
          left = node.child_by_field_name("left")
          operator = node.child(1)
          if left && operator.type == "<<"
            mutation_names(left).each do |name|
              mutations << name
              mutation_counts[name] += 1
              restarts << name
            end
          end
        when "call", "command"
          method = node.child_by_field_name(node.type == "command" ? "name" : "method")
          receiver = node.child_by_field_name("receiver")
          if method && receiver && receiver.text == "Mochi" && TIMER_METHODS.includes?(method.text)
            timer_api = true
          elsif nonvisual_call?(method.try(&.text), receiver.try(&.text))
            nonvisual_api = true
          end
        end
      end

      mutation_counts.each do |name, count|
        restarts << name if count > 1
      end

      HandlerEvidence.new(mutations, restarts, nonvisual_api, timer_api)
    end

    private def self.visit_handler(node : TreeSitter::Node, &block : TreeSitter::Node ->) : Nil
      return if node.type.in?("method", "singleton_method", "class", "module", "singleton_class")
      yield node
      node.each_named_child { |child| visit_handler(child, &block) }
    end

    private def self.mutation_names(node : TreeSitter::Node) : Array(String)
      names = [] of String
      collect_mutations(node, names)
      names
    end

    private def self.collect_mutations(node : TreeSitter::Node, names : Array(String)) : Nil
      case node.type
      when "instance_variable"
        names << node.text.lchop('@')
      when "element_reference"
        first = first_named_child(node)
        collect_mutations(first, names) if first
      when "left_assignment_list", "destructured_left_assignment", "rest_assignment"
        node.each_named_child { |child| collect_mutations(child, names) }
      end
    end

    private def self.instance_variables(node : TreeSitter::Node) : Set(String)
      names = Set(String).new
      visit_instance_variables(node, names)
      names
    end

    private def self.visit_instance_variables(node : TreeSitter::Node, names : Set(String)) : Nil
      names << node.text.lchop('@') if node.type == "instance_variable"
      node.each_named_child { |child| visit_instance_variables(child, names) }
    end

    private def self.first_named_child(node : TreeSitter::Node) : TreeSitter::Node?
      return nil if node.named_child_count == 0
      node.named_child(0)
    end

    private def self.nonvisual_call?(method : String?, receiver : String?) : Bool
      return false unless method
      if receiver == "Mochi"
        return NONVISUAL_MOCHI_METHODS.includes?(method)
      end
      if receiver
        if known = NONVISUAL_RECEIVERS[receiver]?
          return known.includes?(method)
        end
        return method == "emit" if receiver == "self"
        return false
      end
      method == "emit"
    end
  end
end
