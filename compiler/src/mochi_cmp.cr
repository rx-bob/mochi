require "./webcomponents/binding_manifest"

# Helper code that must execute once before components from the same Ruby file.
# `key` is the deterministic .chi filename, not a user-facing component name.
record HelperUnit, key : String, source : String, origin : String

class MochiComponent
  property absolute_path : String
  property name : String
  property imports : Array(String)
  property ruby_code : String
  property manifest : ComponentManifest
  property html : String
  property css : String
  property class_line : Int32

  def initialize(
    @absolute_path : String,
    @name : String,
    @imports : Array(String),
    @ruby_code : String,
    @manifest : ComponentManifest,
    @html : String,
    @css : String,
    @class_line : Int32 = 0,
  )
  end

  def to_s(io : IO)
    io << "MochiComponent(absolute_path: #{absolute_path}, name: #{@name}, ruby_code: #{@ruby_code}, manifest: #{@manifest.tag_name}, html: #{html}, css: #{css})"
  end
end
