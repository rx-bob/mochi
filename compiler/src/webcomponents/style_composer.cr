require "digest/sha1"
require "./resource_manifest"

struct CssComposition
  getter css : String
  getter resources : Array(PackageResource)

  def initialize(@css : String, @resources : Array(PackageResource))
  end

  def style_resource_ids : Array(String)
    @resources.map(&.id)
  end
end

# Composes a component's literal css body with shared files named by CSS
# @import rules. Imports are resolved at build time in source order, recursively
# depth-first, with each fragment emitted once. The component's remaining local
# CSS always follows the shared resources, so a local override wins under both
# the adopted-stylesheet and <style> fallback paths.
class StyleComposer
  private struct ImportRef
    getter path : String
    getter line : Int32

    def initialize(@path : String, @line : Int32)
    end
  end

  @component_name : String
  @source_path : String
  @display_path : String
  @resources : Array(PackageResource)
  @style_ids : Array(String)
  @seen_ids : Set(String)
  @seen_paths : Set(String)

  def initialize(
    @component_name : String,
    @source_path : String,
    display_path : String? = nil,
  )
    @display_path = display_path || @source_path
    @resources = [] of PackageResource
    @style_ids = [] of String
    @seen_ids = Set(String).new
    @seen_paths = Set(String).new
  end

  def compose(css : String) : CssComposition
    local_css, imports = scan(css, @display_path, "component '#{@component_name}'")
    imports.each do |import|
      collect_fragment(import, File.dirname(@source_path), [@source_path])
    end
    CssComposition.new(local_css.strip, @resources)
  end

  private def collect_fragment(import : ImportRef, base_dir : String, stack : Array(String)) : Nil
    path = File.expand_path(import.path, base_dir)
    if stack.includes?(path)
      chain = (stack + [path]).join(" -> ")
      raise "Component '#{@component_name}' has a CSS import cycle at #{import.path}: #{chain}"
    end
    return if @seen_paths.includes?(path)

    unless File.file?(path)
      raise "Component '#{@component_name}' CSS import #{import.path.inspect} at #{@display_path}:#{import.line} was not found (resolved to #{path})"
    end

    @seen_paths << path
    content = File.read(path)
    local_css, imports = scan(content, path, "CSS fragment #{path.inspect} imported by component '#{@component_name}'")
    imports.each do |nested|
      collect_fragment(nested, File.dirname(path), stack + [path])
    end

    local_css = local_css.strip
    return if local_css.empty?

    id = "css-#{Digest::SHA1.hexdigest(local_css)[0, 16]}"
    unless @seen_ids.includes?(id)
      @seen_ids << id
      @resources << PackageResource.new(id, "style", text: local_css, source_path: path)
      @style_ids << id
    end
  end

  private def scan(css : String, context_path : String, context : String) : Tuple(String, Array(ImportRef))
    imports = [] of ImportRef
    local = String::Builder.new
    segment_start = 0
    i = 0
    line = 1
    brace_depth = 0
    seen_local_css = false
    length = css.bytesize

    while i < length
      byte = css.byte_at(i)
      case byte
      when 47 # /
        if i + 1 < length && css.byte_at(i + 1) == 42
          close = css.byte_index("*/", i + 2)
          unless close
            raise_parse(context, context_path, line, "unclosed comment")
          end
          line += css.byte_slice(i, close + 2 - i).count('\n')
          i = close + 2
        else
          seen_local_css = true if brace_depth == 0
          i += 1
        end
      when 34, 39 # " or '
        quote = byte
        j = i + 1
        while j < length
          current = css.byte_at(j)
          if current == 92 # backslash
            j += 2
            next
          end
          if current == quote
            j += 1
            break
          end
          j += 1
        end
        if j > length || css.byte_at(j - 1) != quote
          raise_parse(context, context_path, line, "unclosed string")
        end
        line += css.byte_slice(i, j - i).count('\n')
        seen_local_css = true if brace_depth == 0
        i = j
      when 123 # {
        brace_depth += 1
        seen_local_css = true if brace_depth == 1
        i += 1
      when 125 # }
        if brace_depth == 0
          raise_parse(context, context_path, line, "unexpected closing brace")
        end
        brace_depth -= 1
        i += 1
      when 35 # #
        if i + 1 < length && css.byte_at(i + 1) == 123
          raise_parse(context, context_path, line, "CSS interpolation is not supported; use a build-time fragment or a custom property")
        end
        seen_local_css = true if brace_depth == 0
        i += 1
      when 64 # @
        if brace_depth == 0 && at_import?(css, i)
          if seen_local_css
            raise_parse(context, context_path, line, "@import must appear before local CSS")
          end
          import, finish, consumed_newlines, error = parse_import(css, i, context_path)
          if error
            raise_parse(context, context_path, line, error)
          end
          local << css.byte_slice(segment_start, i - segment_start)
          imports << ImportRef.new(import.not_nil!, line)
          line += consumed_newlines
          i = finish.not_nil!
          segment_start = i
        else
          seen_local_css = true if brace_depth == 0
          i += 1
        end
      else
        if brace_depth == 0 && !whitespace?(byte)
          seen_local_css = true
        end
        line += 1 if byte == 10
        i += 1
      end
    end

    if brace_depth != 0
      raise_parse(context, context_path, line, "unclosed block")
    end
    local << css.byte_slice(segment_start, length - segment_start)
    {local.to_s, imports}
  end

  private def at_import?(css : String, index : Int32) : Bool
    keyword = "@import"
    return false if index + keyword.bytesize > css.bytesize
    return false unless css.byte_slice(index, keyword.bytesize) == keyword
    finish = index + keyword.bytesize
    finish >= css.bytesize || whitespace?(css.byte_at(finish))
  end

  private def parse_import(
    css : String,
    index : Int32,
    context_path : String,
  ) : Tuple(String?, Int32?, Int32, String?)
    length = css.bytesize
    i = index + 7
    i = skip_whitespace(css, i)
    if i + 4 <= length && css.byte_slice(i, 4) == "url("
      i = skip_whitespace(css, i + 4)
    end
    unless i < length && (css.byte_at(i) == 34 || css.byte_at(i) == 39)
      return {nil, nil, 0, "unsupported @import syntax; use @import \"fragment.css\";"}
    end

    quote = css.byte_at(i)
    start = i + 1
    i = start
    while i < length
      current = css.byte_at(i)
      if current == 92
        i += 2
        next
      end
      break if current == quote
      if current == 10 || current == 13
        return {nil, nil, 0, "CSS import path cannot span lines"}
      end
      i += 1
    end
    if i >= length
      return {nil, nil, 0, "unclosed CSS import path"}
    end
    path = css.byte_slice(start, i - start)
    i += 1
    i = skip_whitespace(css, i)
    i += 1 if i < length && css.byte_at(i) == 41 # )
    i = skip_whitespace(css, i)
    unless i < length && css.byte_at(i) == 59 # ;
      return {nil, nil, 0, "CSS import must end with a semicolon"}
    end
    finish = i + 1
    {path, finish, css.byte_slice(index, finish - index).count('\n'), nil}
  end

  private def skip_whitespace(css : String, index : Int32) : Int32
    i = index
    while i < css.bytesize && whitespace?(css.byte_at(i))
      i += 1
    end
    i
  end

  private def whitespace?(byte : UInt8) : Bool
    byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
  end

  private def raise_parse(context : String, path : String, line : Int32, message : String) : NoReturn
    raise "#{context} CSS parse error at #{path}:#{line}: #{message}"
  end
end
