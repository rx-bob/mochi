require "./webcomponents/binding_manifest"
require "./clay/profile"

# Helper code that must execute once before components from the same Ruby file.
# `key` is the deterministic .chi filename, not a user-facing component name.
# `absolute_path` is build-local and never serialized.
record HelperUnit,
  key : String,
  source : String,
  origin : String,
  absolute_path : String? = nil

# A Ruby file with no component classes. It is compiled as its own dependency
# package instead of being merged into an eager shared prelude.
record PreludeSource,
  absolute_path : String,
  source_path : String,
  source : String

class MochiComponent
  property absolute_path : String
  property name : String
  property imports : Array(String)
  property ruby_code : String
  property manifest : ComponentManifest
  property html : String
  property css : String
  property class_line : Int32
  # Path shown to developers. It stays stable after the build removes its
  # temporary pre-transpile copy.
  property source_path : String
  # Line in the original file that generated source line 1 maps to.
  property source_line_offset : Int32
  # Source slice before html/css and generated helper methods were rewritten.
  # The dependency graph uses it to find require, constant, and component
  # references without serializing the source into the manifest.
  property original_source : String = ""
  property portable_profile : ClayProfile?

  def initialize(
    @absolute_path : String,
    @name : String,
    @imports : Array(String),
    @ruby_code : String,
    @manifest : ComponentManifest,
    @html : String,
    @css : String,
    @class_line : Int32 = 0,
    source_path : String? = nil,
    source_line_offset : Int32 = 1,
  )
    @source_path = source_path || @absolute_path
    @source_line_offset = source_line_offset
  end

  def to_s(io : IO)
    io << "MochiComponent(absolute_path: #{absolute_path}, name: #{@name}, ruby_code: #{@ruby_code}, manifest: #{@manifest.tag_name}, html: #{html}, css: #{css})"
  end
end
