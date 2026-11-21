require "digest/sha1"
require "../webcomponents/style_composer"

record PortableStyleRule, name : String, declarations : Hash(String, String), font_locations : Hash(String, String),
  max_width : Int32? = nil

# Ordered single-class rules shared by both renderers. Shared CSS stays in
# independently cached fragments, and the component's own rules come last.
class PortableStyles
  CLASS_SEPARATOR = /[\t\n\f\r ]+/

  getter rules = [] of PortableStyleRule
  getter lookup = {} of String => Array(Int32)

  def append(rules : Array(PortableStyleRule)) : Nil
    rules.each do |rule|
      (@lookup[rule.name] ||= [] of Int32) << @rules.size
      @rules << rule
    end
  end

  def indices(classes : String) : Array(Int32)
    classes.split(CLASS_SEPARATOR).uniq.flat_map { |name| @lookup[name]? || [] of Int32 }.sort!
  end

  def self.css(rules : Array(PortableStyleRule)) : String
    String.build do |io|
      rules.each do |rule|
        if width = rule.max_width
          io << "@container mochi-portable-root (max-width:" << width << "px){"
        end
        io << "." << rule.name << "{"
        rule.declarations.each do |name, value|
          io << name << ":" << value << ";"
          case name
          when "display"
            io << "--mochi-flex-default:row;--mochi-align-default:flex-start;"
          when "flex-direction"
            io << "align-items:" << (value == "row" ? "flex-start" : "stretch") << ";"
          when "width", "height"
            io << "min-" << name << ":" << (value == "auto" ? "0" : value) << ";"
          when "overflow-y"
            io << "overflow-x:hidden;scrollbar-width:none;overflow-anchor:none;"
          end
        end
        io << "}\n"
        io << "." << rule.name << ">*{flex-shrink:0}\n" if rule.declarations.has_key?("overflow-y")
        io << "}\n" if rule.max_width
      end
    end
  end

  def self.resource(css : String, original : PackageResource) : PackageResource
    # Keep the authored import identity so separated repetitions of distinct
    # imports retain their order even if normalization yields the same CSS.
    id = "css-#{Digest::SHA1.hexdigest(original.id + css)[0, 16]}"
    PackageResource.new(id, "style", text: css)
  end

  EDITOR_CSS = "label{display:block;box-sizing:border-box}input{box-sizing:border-box;min-width:0;margin:0;font:inherit;color:inherit;height:30px}" +
               "input:where([type=checkbox]){width:18px;height:18px;align-self:flex-start}"

  CSS_RESET = ":host{display:flex;flex-direction:column;min-width:0;color:#000000;font-family:sans-serif;font-size:16px;font-weight:400;line-height:20px;font-synthesis:none}" +
              "div,span,button{box-sizing:border-box;min-width:0;--mochi-flex-default:initial;--mochi-align-default:initial}" +
              "div,button{display:flex;flex-direction:var(--mochi-flex-default,column);align-items:var(--mochi-align-default,stretch)}" +
              "button{appearance:none;font:inherit;color:inherit;background:transparent;border:0;margin:0;padding:0;text-align:left}"
end
