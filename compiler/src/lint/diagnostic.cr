require "json"

module Lint
  SYNTAX_RULE      = "ruby/syntax"
  ANALYSIS_RULE    = "analysis/limitation"
  SUPPRESSION_RULE = "lint/suppression"

  enum Severity
    Error
    Warning

    def label : String
      error? ? "error" : "warning"
    end
  end

  module Diagnostics
    # Paths are project-relative and already normalized by FileDiscovery.
    # The input position is the final tie-breaker so the order is stable even
    # when two passes produce otherwise identical records.
    def self.sort(diagnostics : Array(Diagnostic)) : Array(Diagnostic)
      diagnostics.map_with_index { |diagnostic, index| {diagnostic, index} }
        .sort_by do |(diagnostic, index)|
          {
            diagnostic.path,
            diagnostic.start_byte,
            diagnostic.rule,
            diagnostic.message,
            diagnostic.end_byte,
            diagnostic.severity.label,
            diagnostic.suggestion || "",
            index,
          }
        end
        .map(&.first)
    end
  end

  class Diagnostic
    getter path : String
    getter start_line : Int32
    getter start_column : Int32
    getter end_line : Int32
    getter end_column : Int32
    getter start_byte : Int32
    getter end_byte : Int32
    getter severity : Severity
    getter rule : String
    getter message : String
    getter suggestion : String?

    def initialize(
      @path : String,
      @start_line : Int32,
      @start_column : Int32,
      @end_line : Int32,
      @end_column : Int32,
      @start_byte : Int32,
      @end_byte : Int32,
      @severity : Severity,
      @rule : String,
      @message : String,
      @suggestion : String? = nil,
    )
    end

    def to_text : String
      "#{@path}:#{@start_line}:#{@start_column}: #{@severity.label} #{@rule}: #{@message}"
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "path", @path
        json.field "line", @start_line
        json.field "column", @start_column
        json.field "end_line", @end_line
        json.field "end_column", @end_column
        json.field "start_byte", @start_byte
        json.field "end_byte", @end_byte
        json.field "severity", @severity.label
        json.field "rule", @rule
        json.field "message", @message
        if suggestion = @suggestion
          json.field "suggestion", suggestion
        end
      end
    end
  end
end
