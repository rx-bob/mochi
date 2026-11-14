require "colorize"
require "./sorbet"
require "./component_source_preparer"

# Runs the in-process Sorbet LSP session over an already prepared Ruby source
# tree. BuildMain uses it after copying components into `build/src`; the
# standalone Typechecker uses the same path after its own setup step.
class ProjectTypechecker
  def initialize(@root_dir : String)
  end

  def typecheck : Bool
    files = Dir.glob(File.join(@root_dir, "**", "*.rb"))
    if files.empty?
      STDERR.puts "Error: Cannot run typechecks, no ruby files found in #{@root_dir}".colorize(:red)
      return false
    end

    puts "Typechecking #{files.size} files..."
    prepared = files.to_h { |file| {file, ComponentTypecheckSource.prepare_with_map(File.read(file), file)} }
    session = Sorbet::Session.new(
      root_dir: @root_dir,
      multi_threaded: false
    )

    begin
      result = session.typecheck_files(prepared.transform_values(&.code))
    ensure
      session.close
    end

    if result.success?
      puts "✓ No type errors found!".colorize(:green)
      return true
    end

    puts "✗ Found errors:".colorize(:red)
    result.errors.each_with_index do |error, index|
      trimmed_file_path = error.file[@root_dir.size, error.file.size]
      column = prepared[error.file]?.try(&.authored_column(error.line, error.column)) || error.column
      location = "#{trimmed_file_path}@#{error.line + 1}:#{column + 1}"
      puts "  [Error ##{index + 1}]  #{error.message.colorize(:red)} [#{location.colorize(:yellow)}]"
    end
    false
  end
end
