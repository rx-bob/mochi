require "../webcomponents/binding_manifest"
require "./portable_styles"
require "../tooling/portable_project"

# Serialize only typed compiler records. No browser markup or DOM paths
# are part of the native scene schema.
class DesktopScene
  VERSION = 4

  def initialize(@manifest : ComponentManifest, @styles : PortableStyles, @window : PortableWindow?)
  end

  def write(packages : Array(String), fingerprint : String, fonts : PortableFonts) : String
    JSON.build do |j|
      j.object do
        j.field "version", VERSION
        j.field "capacity", fingerprint
        j.field "class", @manifest.class_name
        j.field "tag", @manifest.tag_name
        j.field "source", @manifest.source_file
        j.field "methods", @manifest.method_lines
        j.field "packages", packages
        j.field "font_assets", fonts.faces
        j.field "font_licenses", fonts.licenses.to_a.sort
        j.field "font_stacks", fonts.native_stacks
        j.field "getters", @manifest.all_bindings.to_h { |b| {b.id.to_s, b.getter_sym} }
        j.field "window", @window if @window
        j.field "style_lookup", @styles.lookup
        j.field "styles" do
          j.array do
            @styles.rules.each do |rule|
              j.object do
                rule.declarations.each do |key, value|
                  case key
                  when "color"            then j.field "ink", value[1..].to_i(16)
                  when "background-color" then j.field "fill", value[1..].to_i(16)
                  when "width", "height"
                    j.field key, value == "auto" ? -1 : value.to_i(strict: false)
                  when "gap", "padding" then j.field key, value.to_i(strict: false)
                  when "font-size"      then j.field "size", value.to_i(strict: false)
                  when "line-height"    then j.field "leading", value.to_i(strict: false)
                  when "font-weight"    then j.field "weight", value.to_i
                  when "font-family"    then j.field "face", value
                  when "display"        then j.field "flex", true
                  when "flex-direction" then j.field "vertical", value == "column"
                  end
                end
              end
            end
          end
        end
        j.field("nodes") { nodes(j, @manifest.portable_nodes.not_nil!) }
      end
    end
  end

  private def nodes(json, list)
    json.array do
      list.each do |node|
        next if node.is_a?(PortableTemplate::Comment) || (node.is_a?(PortableTemplate::Text) && !node.visible?)
        json.object do
          json.field "id", node.id
          span = node.span.not_nil!
          json.field "span" do
            json.object do
              json.field "file", span.file
              json.field "line", span.line
              json.field "column", span.column
              json.field "end_line", span.end_line
              json.field "end_column", span.end_column
            end
          end
          case node
          when PortableTemplate::Conditional
            json.field "type", "cond"
            json.field "binding", node.binding
            json.field("branches") { json.array { node.branches.each { |branch| nodes(json, branch) } } }
          when PortableTemplate::Rows
            json.field "type", "each"
            json.field "binding", node.binding
            json.field("nodes") { nodes(json, node.children) }
          when PortableTemplate::Text
            json.field "type", "text"
            json.field("parts") { parts(json, node.parts) }
          when PortableTemplate::Element
            element(json, node)
          end
        end
      end
    end
  end

  private def element(json, node : PortableTemplate::Element) : Nil
    json.field "type", {"div" => "box", "span" => "label", "button" => "button"}[node.tag]
    if action = node.action
      json.field "action", action.method
      json.field "event_args", action.event_args
      json.field "row_context", true if action.row_context
    end

    classes = node.attributes["class"]? || PortableTemplate::Parts.new
    if classes.all?(&.is_a?(String))
      json.field "styles", @styles.indices(classes.join)
    else
      json.field("style_names") { parts(json, classes) }
    end

    json.field "attrs" do
      json.object do
        node.attributes.each do |name, values|
          json.field(name) { parts(json, values) } unless name == "class"
        end
      end
    end
    json.field("nodes") { nodes(json, node.children) }
  end

  private def parts(json, parts : PortableTemplate::Parts) : Nil
    json.array do
      parts.each do |part|
        case part
        when String
          json.string part
        when PortableTemplate::BindingOperand
          json.object { json.field "binding", part.id }
        when PortableTemplate::RowOperand
          json.object { json.field "slot", part.slot }
        end
      end
    end
  end
end
