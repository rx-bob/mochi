require "./diagnostic"

module Lint
  enum RuleLevel
    Error
    Warning
    Off

    def label : String
      case self
      when .error?   then "error"
      when .warning? then "warning"
      else                "off"
      end
    end

    def self.parse?(value : String) : RuleLevel?
      case value
      when "error"   then Error
      when "warning" then Warning
      when "off"     then Off
      end
    end
  end

  record RuleOption, name : String, default_value : Int32

  class RuleSettings
    getter level : RuleLevel
    getter options : Hash(String, Int32)

    def initialize(@level : RuleLevel, @options : Hash(String, Int32) = {} of String => Int32)
    end

    def enabled? : Bool
      !@level.off?
    end

    def severity : Severity?
      case @level
      when .error?   then Severity::Error
      when .warning? then Severity::Warning
      end
    end

    def [](option : String) : Int32?
      @options[option]?
    end
  end

  class RuleDefinition
    getter id : String
    getter default_level : RuleLevel
    getter description : String
    getter options : Hash(String, RuleOption)
    getter? configurable : Bool

    def initialize(
      @id : String,
      @default_level : RuleLevel,
      @description : String,
      @options : Hash(String, RuleOption) = {} of String => RuleOption,
      @configurable : Bool = true,
    )
    end

    def default_options : Hash(String, Int32)
      values = {} of String => Int32
      @options.each { |name, option| values[name] = option.default_value }
      values
    end

    def default_settings : RuleSettings
      RuleSettings.new(@default_level, default_options)
    end
  end

  module RuleRegistry
    RULES = {
      "ruby/syntax" => RuleDefinition.new(
        "ruby/syntax",
        RuleLevel::Error,
        "Ruby syntax and Tree-sitter recovery errors",
        configurable: false,
      ),
      "analysis/limitation" => RuleDefinition.new(
        "analysis/limitation",
        RuleLevel::Error,
        "Source that lint cannot analyze with an exact original location",
        configurable: false,
      ),
      "lint/suppression" => RuleDefinition.new(
        "lint/suppression",
        RuleLevel::Error,
        "Inline suppression directives are valid, narrow, and still needed",
        configurable: false,
      ),
      "correctness/unknown-handler" => RuleDefinition.new(
        "correctness/unknown-handler",
        RuleLevel::Error,
        "Template event handlers resolve to component methods",
      ),
      "correctness/timer-callback" => RuleDefinition.new(
        "correctness/timer-callback",
        RuleLevel::Error,
        "Literal Mochi timer callbacks use zero-argument methods",
      ),
      "correctness/child-props" => RuleDefinition.new(
        "correctness/child-props",
        RuleLevel::Error,
        "Child component props match their declared contracts",
      ),
      "correctness/event-payload" => RuleDefinition.new(
        "correctness/event-payload",
        RuleLevel::Error,
        "Declared child event payloads match their schemas",
      ),
      "components/prop-write" => RuleDefinition.new(
        "components/prop-write",
        RuleLevel::Warning,
        "Declared props remain read-only input snapshots",
      ),
      "metrics/method-length" => RuleDefinition.new(
        "metrics/method-length",
        RuleLevel::Warning,
        "Ruby method bodies stay within the configured line limit",
        {"max" => RuleOption.new("max", 60)},
      ),
      "metrics/nesting-depth" => RuleDefinition.new(
        "metrics/nesting-depth",
        RuleLevel::Warning,
        "Ruby method logic stays within the configured nesting limit",
        {"max" => RuleOption.new("max", 4)},
      ),
      "metrics/component-methods" => RuleDefinition.new(
        "metrics/component-methods",
        RuleLevel::Warning,
        "Components stay within the configured authored method limit",
        {"max" => RuleOption.new("max", 40)},
      ),
      "accessibility/control-name" => RuleDefinition.new(
        "accessibility/control-name",
        RuleLevel::Warning,
        "Interactive controls have an accessible name",
      ),
      "accessibility/keyboard-activation" => RuleDefinition.new(
        "accessibility/keyboard-activation",
        RuleLevel::Warning,
        "Custom button roles provide local keyboard activation",
      ),
      "templates/unstable-key" => RuleDefinition.new(
        "templates/unstable-key",
        RuleLevel::Off,
        "Lists use stable row identity when reordering is visible",
      ),
      "migration/css-timer" => RuleDefinition.new(
        "migration/css-timer",
        RuleLevel::Off,
        "Hidden CSS animation timer loops migrate to Mochi timers",
      ),
      "money/float-to-minor-units" => RuleDefinition.new(
        "money/float-to-minor-units",
        RuleLevel::Off,
        "Currency display uses exact minor-unit arithmetic",
      ),
    }

    def self.[](id : String) : RuleDefinition
      RULES[id]? || raise KeyError.new("unknown lint rule: #{id}")
    end

    def self.[]?(id : String) : RuleDefinition?
      RULES[id]?
    end

    def self.default_rules : Hash(String, RuleSettings)
      rules = {} of String => RuleSettings
      RULES.each { |id, definition| rules[id] = definition.default_settings }
      rules
    end
  end
end
