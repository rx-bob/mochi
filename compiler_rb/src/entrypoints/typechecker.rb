module Mochi
  # Stub class for standalone typechecking logic.
  # Full implementation deferred per RUBY_PORT.md Appendix D.
  class Typechecker
    extend T::Sig

    sig { params(path: String).void }
    def typecheck(path)
      puts "Typechecking #{path}..."
      puts "Typecheck stub"
    end

    sig { void }
    def run
      puts "Standalone typecheck stub"
    end
  end
end
