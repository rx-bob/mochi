# typed: false
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "opal"

module QuickJS
  module Opal
    class Builder
      extend T::Sig

      sig { params(include_runtime: T::Boolean).void }
      def initialize(include_runtime: true)
        @compiler = T.let(Compiler.new, Compiler)
        @parts = T.let(T::Array[String].new, T::Array[String])

        add_vendor_file("opal.js") if include_runtime
      end

      sig { void }
      def finalize
        @compiler.finalize
      end

      sig { params(content: String).void }
      def add_raw_js(content)
        @parts << content
      end

      sig { params(name: String).void }
      def add_stdlib(name)
        filename = name.end_with?(".js") ? name : "#{name}.js"
        root = resolve_vendor_root
        path = "#{root}/opal/#{filename}"

        if File.exist?(path)
          @parts << File.read(path)
        else
          puts "Warning: Opal stdlib #{name} not found at #{path}"
        end
      end

      sig { returns(String) }
      def resolve_vendor_root
        exe_dir = File.dirname($PROGRAM_NAME)
        candidates = [
          File.expand_path("../../../fragments/vendor", __dir__),
          File.expand_path("../../fragments/vendor", __dir__),
          File.join(exe_dir, "../fragments/vendor"),
          File.join(exe_dir, "fragments/vendor"),
        ]
        candidates.find { |p| Dir.exist?(File.join(p, "opal")) } || "fragments/vendor"
      end

      sig { params(filename: String).void }
      def add_vendor_file(filename)
        root = resolve_vendor_root
        path = "#{root}/opal/#{filename}"
        if File.exist?(path)
          @parts << File.read(path)
        else
          raise "Vendor file #{filename} not found at #{path}"
        end
      end

      sig { params(path: String).void }
      def add_directory(path)
        Dir.glob(File.join(path, "**", "*.rb")).each do |file|
          if File.file?(file)
            content = File.read(file)
            relative_path = Pathname.new(file).relative_path_from(Pathname.new(path)).to_s
            compile(content, relative_path)
          end
        end
      end

      sig { params(code: String, path: String, cache: T.untyped, requirable: T::Boolean).void }
      def compile_with_cache(code, path, cache, requirable: true)
        require "digest/md5"

        compiled = ""
        cache_key = Digest::MD5.hexdigest("#{path}::#{code}")
        if cache.respond_to?(:has) && cache.has(cache_key)
          compiled = cache.get(cache_key)
        else
          compiled = @compiler.compile(code, path, requirable)
          cache.put(cache_key, compiled) if cache.respond_to?(:put)
        end

        @parts << compiled
      end

      sig { params(code: String, path: String, requirable: T::Boolean).void }
      def compile(code, path, requirable: true)
        compiled = @compiler.compile(code, path, requirable)
        @parts << compiled
      end

      sig { params(entry_point: T.nilable(String)).returns(String) }
      def build(entry_point = nil)
        final = @parts.join("\n")
        if entry_point
          mod_name = entry_point.chomp(".rb")
          final += "\nOpal.require('#{mod_name}');"
        end
        final
      end
    end
  end
end
