require "colorize"
require "./building/build_main"
require "../sorbet/project_typechecker"

class Typechecker
  def typecheck(input_dir : String)
    builder_man = BuilderMan.new(input_dir)
    # steps 2-4
    BuildMain.new.setup(builder_man)

    root_dir = builder_man.ruby_src_dir
    files = Dir.glob(File.join(root_dir, "**", "*.rb"))
    if files.size < 1
      STDERR.puts "Error: Cannot run typechecks, no ruby files found"
      exit 1
    end

    # Keep the legacy standalone typechecker's dependency setup; the build
    # pipeline skips this network step and typechecks the prepared tree.
    `cd #{root_dir} && bundle install > /dev/null 2>&1`

    success = ProjectTypechecker.new(root_dir).typecheck
    exit 1 unless success
  end
end
