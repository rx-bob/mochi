require "../diagnostic"
require "../project_index"
require "./complexity"

module Lint::Rules
  # Reports source lines that exceed the configured character width. The rule
  # is opt-in: projects that want a line-length limit enable it explicitly.
  module LineLength
    RULE        = "metrics/line-length"
    DEFAULT_MAX = 120

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      max = settings["max"] || DEFAULT_MAX
      issues = [] of SourceIssue

      Complexity.each_method(index) do |method|
        first_row = method.node.start_point.row.to_i
        last_row = method.node.end_point.row.to_i
        (first_row..last_row).each do |row|
          start = method.unit.map.line_starts[row]?
          next unless start

          finish = line_finish(method.unit, row)
          width = method.unit.source.byte_slice(start, finish - start).size
          next if width <= max

          range = method.unit.map.range(start, finish)
          issues << SourceIssue.new(
            method.unit.file.relative_path,
            method.unit.map,
            range.start_byte,
            range.end_byte,
            "line has #{width} characters; maximum is #{max}",
            RULE,
            "Wrap this line or move embedded data outside the method.",
          )
        end
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end

    private def self.line_finish(unit : SourceUnit, row : Int32) : Int32
      starts = unit.map.line_starts
      finish = row + 1 < starts.size ? starts[row + 1] : unit.source.bytesize
      finish -= 1 if finish > 0 && unit.source.byte_at(finish - 1) == 10_u8
      finish -= 1 if finish > 0 && unit.source.byte_at(finish - 1) == 13_u8
      finish
    end
  end
end
