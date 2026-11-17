require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Counts Ruby source files directly inside each package directory. The rule
  # reports one directory at a time and points at the first class or module in
  # the first selected file so a local suppression can carry its reason.
  module PackageFiles
    RULE        = "structure/package-files"
    DEFAULT_MAX = 10

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      settings = index.config.settings_for(RULE)
      return [] of Diagnostic unless settings.enabled?
      severity = settings.severity
      return [] of Diagnostic unless severity

      max = settings["max"] || DEFAULT_MAX
      packages = {} of String => Array(SourceUnit)

      index.units.values.each do |unit|
        package = File.dirname(unit.file.relative_path).gsub('\\', '/')
        packages[package] ||= [] of SourceUnit
        packages[package] << unit
      end

      issues = [] of SourceIssue
      packages.each do |package, units|
        next if units.size <= max

        ordered = units.sort_by(&.file.relative_path)
        unit = ordered.find { |candidate| !candidate.declarations.empty? } || ordered.first
        start_byte, end_byte = diagnostic_range(unit)
        issues << SourceIssue.new(
          unit.file.relative_path,
          unit.map,
          start_byte,
          end_byte,
          "package '#{package}' has #{units.size} Ruby files; maximum is #{max}",
          RULE,
          "Split the package into subdirectories with at most #{max} Ruby files each.",
        )
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end

    private def self.diagnostic_range(unit : SourceUnit) : Tuple(Int32, Int32)
      if declaration = unit.declarations.first?
        return {declaration.start_byte, declaration.end_byte}
      end

      finish = unit.map.line_starts[1]? || unit.source.bytesize
      {0, finish}
    end
  end
end
