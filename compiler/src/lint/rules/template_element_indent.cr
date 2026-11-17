require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Requires a multi-line element's closing tag to start at the same column as
  # its opening tag. Inline elements and elements opened mid-line are skipped.
  module TemplateElementIndent
    RULE = "style/template-element-indent"

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      issues = [] of SourceIssue
      index.target_templates.each do |view|
        view.elements.elements.each do |element|
          close_start = element.close_start
          end_byte = element.end_byte
          next unless close_start && end_byte
          next unless close_start > element.finish
          next unless line_leading?(view, element.start)

          open_position = view.map.position(view.source_byte(element.start))
          close_position = view.map.position(view.source_byte(close_start))
          next if open_position.line == close_position.line
          next if open_position.column == close_position.column

          range = view.source_range(close_start, end_byte)
          issues << SourceIssue.new(
            view.unit_path,
            view.map,
            range.start_byte,
            range.end_byte,
            "closing tag indentation does not match its opening tag",
            RULE,
            "Align </#{element.tag}> with <#{element.tag}>.",
          )
        end
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end

    private def self.line_leading?(view : TemplateView, offset : Int32) : Bool
      source_byte = view.source_byte(offset)
      line = view.map.position(source_byte).line
      line_start = view.map.line_start(line)
      prefix = view.map.source.byte_slice(line_start, source_byte - line_start)
      prefix.each_char.all? { |char| char == ' ' || char == '\t' }
    end
  end
end
