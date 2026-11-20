require "../html/dom_attributes"
require "../webcomponents/binding_manifest"

# Resolve DOM paths while the compiler still has the parsed template. The
# desktop descriptor contains only node IDs, literal segments and VM slots.
class DesktopScene
  @next_id = 0

  def initialize(@manifest : ComponentManifest)
  end

  def write(packages : Array(String), fingerprint : String) : String
    @next_id = 0
    JSON.build do |j|
      j.object do
        j.field "version", 1
        j.field "capacity", fingerprint
        j.field "class", @manifest.class_name
        j.field "source", @manifest.source_file
        j.field "methods", @manifest.method_lines
        j.field "packages", packages
        j.field "getters", @manifest.all_bindings.to_h { |b| {b.id.to_s, b.getter_sym} }
        j.field "styles" do
          j.array do
            @manifest.desktop_styles.each do |name, declarations|
              j.object do
                j.field "name", name
                j.field "values" do
                  j.object do
                    declarations.each do |key, value|
                      case key
                      when "color"            then j.field "ink", value[1..].to_i(16)
                      when "background-color" then j.field "fill", value[1..].to_i(16)
                      when "width", "height", "gap", "padding"
                        j.field key, value.to_i(strict: false)
                      when "font-size"      then j.field "size", value.to_i(strict: false)
                      when "line-height"    then j.field "leading", value.to_i(strict: false)
                      when "font-weight"    then j.field "weight", value.to_i
                      when "font-family"    then j.field "face", value.split(',').first.strip
                      when "display"        then j.field "flex", true
                      when "flex-direction" then j.field "vertical", value == "column"
                      end
                    end
                  end
                end
              end
            end
          end
        end
        j.field("nodes") { fragment(j, @manifest.html_template, @manifest.bindings, @manifest.events) }
      end
    end
  end

  private def fragment(j, html, bindings, events, row = false)
    # The wrapper preserves leading whitespace and comments. These count in
    # compiler binding paths even though they have no native representation.
    root = Lexbor.new("<body><div>#{html}</div></body>").body.not_nil!.children.first
    children(j, root, [] of Int32, bindings, events, row)
  end

  private def children(j, parent, prefix, bindings, events, row)
    j.array do
      parent.children.each_with_index do |node, i|
        path = prefix + [i]
        local = bindings.select { |b| b.path == path }
        tag = node.tag_name
        next if tag == "_text" && node.tag_text.strip.empty?
        next if tag == "_em_comment" && local.empty?
        @next_id += 1
        j.object do
          j.field "id", @next_id
          case tag
          when "_em_comment"
            if parent.tag_name.in?("span", "button")
              raise "#{@manifest.source_file}: desktop text leaves support scalar bindings; place conditionals and lists around the leaf"
            end
            b = local.first
            j.field "type", b.kind
            j.field "binding", b.id
            if rows = b.each_rows
              unless rows.key_expression && rows.children.empty? && rows.conditionals.empty?
                raise "#{rows.span}: desktop lists require an explicit key and a flat row template"
              end
              j.field("nodes") { fragment(j, rows.template, [] of BindingDescriptor, [] of EventDescriptor, true) }
            else
              j.field("branches") do
                j.array { b.branches.each { |branch| fragment(j, branch.html_template, branch.bindings, branch.events) } }
              end
            end
          when "_text"
            j.field "type", "text"
            j.field("parts") { parts(j, node.tag_text, local, row) }
          when "div", "span", "button"
            j.field "type", {"div" => "box", "span" => "label", "button" => "button"}[tag]
            attrs = DomAttributes.read(node)
            if method = attrs.delete("data-mochi-click")
              j.field "action", method
              if !row && (event = events.find { |e| e.path == path && e.event == "click" })
                unless event.args.size <= 1 && event.args.all? { |arg| arg.kind == "event" }
                  raise "#{@manifest.source_file}: desktop buttons accept a handler or $event"
                end
                j.field "event_args", event.args.size
              end
            end
            classes = attrs.delete("class") || ""
            class_fields = local.select { |b| b.attr_name == "class" }
            if !class_fields.empty? || (row && classes.includes?('\uE002'))
              j.field("style_names") { parts(j, classes, class_fields, row) }
            else
              names = classes.split
              j.field("styles") do
                j.array do
                  @manifest.desktop_styles.each_with_index { |(name, _), i| j.number(i) if names.includes?(name) }
                end
              end
            end
            j.field("attrs") do
              j.object do
                attrs.each do |name, value|
                  fields = local.select { |b| b.attr_name == name }
                  j.field(name) { parts(j, value, fields, row) }
                end
              end
            end
            j.field("nodes") { children(j, node, path, bindings, events, row) }
          else
            raise "#{@manifest.source_file}: unsupported desktop node #{tag}"
          end
        end
      end
    end
  end

  private def parts(j, value, fields, row)
    j.array do
      at = 0
      if row
        value.scan(/\x{E002}(\d+)\x{E003}/) do |m|
          start = m.byte_begin(0)
          j.string value.byte_slice(at, start - at) if start > at
          j.object { j.field "slot", m[1].to_i }
          at = m.byte_end(0)
        end
      else
        value = fields.first?.try(&.template_text) || value
        fields.sort_by(&.template_start.not_nil!).each do |b|
          start = b.template_start.not_nil!
          j.string value.byte_slice(at, start - at) if start > at
          j.object { j.field "binding", b.id }
          at = b.template_end.not_nil!
        end
      end
      j.string value.byte_slice(at) if at < value.bytesize
    end
  end
end
