require "../tree-sitter/property_extractor"

# Adapt compiler-owned declarations only in Sorbet's isolated source view.
# Boolean is metadata, not a global Ruby constant or a shipped runtime class.
class ComponentTypecheckSource
  record ColumnEdit, line : Int32, start : Int32, finish : Int32, width : Int32
  record Prepared, code : String, columns : Array(ColumnEdit) do
    # The embedded Sorbet reports byte columns. Adaptations add no newlines.
    def authored_column(line : Int32, column : Int32) : Int32
      shift = 0
      columns.each do |edit|
        next unless edit.line == line
        start = edit.start + shift
        break if column < start
        if column < start + edit.width
          return edit.start + Math.min(column - start, edit.finish - edit.start)
        end
        shift += edit.width - (edit.finish - edit.start)
      end
      column - shift
    end
  end

  def self.prepare(source : String, file : String) : String
    prepare_with_map(source, file).code
  end

  def self.prepare_with_map(source : String, file : String) : Prepared
    tree = TreeSitter::RubyParser.new.parse(source)
    edits = [] of Tuple(Int32, Int32, String)
    visit(tree.root_node, file, edits)
    columns = edits.sort_by(&.[0]).map do |start, finish, replacement|
      prefix = source.byte_slice(0, start)
      column = prefix.split('\n').last.bytesize
      ColumnEdit.new(prefix.count('\n'), column, column + finish - start, replacement.bytesize)
    end
    edits.sort_by { |edit| -edit[0] }.each do |start, finish, replacement|
      source = source.byte_slice(0, start) + replacement + source.byte_slice(finish)
    end
    Prepared.new(source, columns)
  end

  private def self.visit(node : TreeSitter::Node, file : String, edits : Array(Tuple(Int32, Int32, String)))
    if node.type == "class" && (body = node.child_by_field_name("body")) &&
       TreeSitter::PropertyExtractor.extract_property_from_body(body, "@tag_name")
      # Reuse declaration/default validation instead of weakening diagnostics.
      props = TreeSitter::PropertyExtractor.extract_props_from_class(node, file)
      events = TreeSitter::PropertyExtractor.extract_events_from_class(node, file)
      has_emit = false
      body.each_named_child do |child|
        has_emit ||= child.type == "method" && child.child_by_field_name("name").try(&.text) == "emit"
        next unless child.type.in?("call", "command") && child.child_by_field_name("receiver").nil?
        method = child.child_by_field_name("method").try(&.text)
        next unless method == "prop" || method == "event"
        args = child.child_by_field_name("arguments")
        next unless args
        index = -1
        args.each_named_child do |argument|
          index += 1
          type = if method == "prop" && index == 1
                   argument
                 elsif method == "event" && argument.type == "pair"
                   argument.child_by_field_name("value")
                 end
          if type && type.type == "constant" && type.text == "Boolean"
            edits << {type.start_byte, type.end_byte, "T::Boolean"}
          end
        end
      end
      shims = [] of String
      shims << "def self.prop(name, type, required: false, default: nil); end" unless props.empty?
      shims << "def self.event(name, **payload); end" unless events.empty?
      if !events.empty? && !has_emit
        shims << "def emit(event_name, payload = {}); end"
      end
      unless shims.empty?
        # Metadata is compiler-owned; emit is generated after typechecking.
        # Keep shims inside their owning component and preserve source lines.
        insertion = node.end_byte - 3
        edits << {insertion, insertion, shims.join("; ") + "; "}
      end
    end
    node.each_named_child { |child| visit(child, file, edits) }
  end
end
