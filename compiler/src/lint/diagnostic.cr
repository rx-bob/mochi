require "json"

module Lint
  enum Severity
    Error
    Warning

    def label : String
      error? ? "error" : "warning"
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
