# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "../batteries/fragment_loader"
require_relative "../data_models/mochi_component"

class RubyRewriter
  extend T::Sig

  sig { returns(String) }
  def rewrite
    ""
  end

  sig { params(path: String).returns(T.nilable(String)) }
  def extract_lib_path(path)
    index = path.index("lib/")
    return nil unless index

    path[index..]
  end

  sig { params(path: String).returns(String) }
  def format_require_path(path)
    path.sub(/^lib\//, "").sub(/\.rb$/, "")
  end

  sig { params(components: T::Array[MochiComponent]).returns(String) }
  def gen_mochi_ruby_root(components)
    rb_code = T.let("", String)

    rb_code += "require 'opal'\n"
    rb_code += "require 'native'\n"
    rb_code += "require 'promise'\n"
    rb_code += "require 'browser/setup/full'\n"
    rb_code += "require 'mochi'\n"

    components.each do |mochi_comp|
      lib_path = extract_lib_path(mochi_comp.absolute_path)
      if lib_path
        rb_code += "require \"#{format_require_path(lib_path)}\"\n"
      end
    end

    rb_code += "class Root\n"
    rb_code += "end\n"

    rb_code += "\n"
    components.each do |mochi_comp|
      rb_code += "#{mochi_comp.name}.new\n"
    end
    rb_code += "Mochi.new\n"

    rb_code
  end

  sig { returns(String) }
  def gen_builtin_component_feather_icon
    FragmentLoader.load("feather_icon_rb")
  end

  sig { returns(String) }
  def gen_builtin_mochi_router
    FragmentLoader.load("mochi_router_rb")
  end

  sig { returns(String) }
  def gen_builtin_route_component
    FragmentLoader.load("route_rb")
  end

  sig { params(ruby_code: String).returns(String) }
  def comment_out_sorbet_signatures(ruby_code)
    ruby_code.lines(chomp: true).map do |line|
      if line.strip.start_with?("sig {")
        "##{line}"
      else
        line
      end
    end.join("\n")
  end

  sig { params(path: String).void }
  def comment_out_all_sorbet_signatures_in_dir(path)
    unless File.directory?(path)
      STDERR.puts "Error: Provided path is not a directory -> #{path}"
      return
    end

    Dir.each_child(path) do |child|
      full_path = File.join(path, child)

      if File.directory?(full_path)
        comment_out_all_sorbet_signatures_in_dir(full_path)
      elsif File.file?(full_path)
        begin
          content = File.read(full_path)
          File.write(full_path, comment_out_sorbet_signatures(content))
        rescue => e
          STDERR.puts "  -> Could not write to file: #{full_path}. Reason: #{e.message}"
        end
      end
    end
  end
end
