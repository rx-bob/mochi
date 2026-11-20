require "digest/sha1"
require "../webcomponents/style_composer"

record PortableStyleRule, name : String, declarations : Hash(String, String), font_locations : Hash(String, String)

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
          end
        end
        io << "}\n"
      end
    end
  end

  def self.resource(css : String, original : PackageResource) : PackageResource
    # Keep the authored import identity so separated repetitions of distinct
    # imports retain their order even if normalization yields the same CSS.
    id = "css-#{Digest::SHA1.hexdigest(original.id + css)[0, 16]}"
    PackageResource.new(id, "style", text: css)
  end

  CSS_RESET = ":host{color:#000000;font-family:sans-serif;font-size:16px;font-weight:400;line-height:20px;font-synthesis:none}" +
              "div,span,button{box-sizing:border-box;min-width:0;--mochi-flex-default:initial;--mochi-align-default:initial}" +
              "div,button{display:flex;flex-direction:var(--mochi-flex-default,column);align-items:var(--mochi-align-default,stretch)}" +
              "button{appearance:none;font:inherit;color:inherit;background:transparent;border:0;margin:0;padding:0;text-align:left}"
end
