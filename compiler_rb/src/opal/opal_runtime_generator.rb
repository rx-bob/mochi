# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class OpalRuntimeGenerator
  extend T::Sig

  sig { void }
  def initialize
  end

  sig { params(build_dir: String).returns(String) }
  def get_runtime_file_path(build_dir)
    "#{build_dir}/runtime.js"
  end

  sig { params(relative_to_exe: String, fallbacks: T::Array[String]).returns(String) }
  def resolve_path(relative_to_exe, fallbacks)
    # Compute candidate base directories
    ruby_exe_dir = File.expand_path("../../", __dir__)
    crystal_exe_dir = File.expand_path("../../../compiler/", __dir__)

    candidates = T.let([], T::Array[String])
    candidates << File.expand_path(relative_to_exe, ruby_exe_dir)
    candidates << File.expand_path(relative_to_exe, crystal_exe_dir)
    candidates += fallbacks.map { |fb| File.expand_path(fb, Dir.pwd) }

    found = candidates.find { |p| File.exist?(p) }
    return found if found

    T.must(candidates.first)
  end

  sig { params(build_dir: String).void }
  def generate(build_dir)
    output_file = get_runtime_file_path(build_dir)

    base_runtime = File.read(resolve_path("../fragments/vendor/runtime.js", ["../fragments/vendor/runtime.js"]))
    mochi_comp = File.read(resolve_path("src/js/runtime/mochi_component.js", ["src/js/runtime/mochi_component.js"]))
    signal_rt = File.read(resolve_path("src/js/runtime/signal.js", ["src/js/runtime/signal.js"]))

    File.write(output_file, base_runtime + "\n" + signal_rt + "\n" + mochi_comp)
  end
end
