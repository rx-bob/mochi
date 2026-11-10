require "./webcomponents/binding_manifest"

class MochiComponent
  property absolute_path : String
  property name : String
  property imports : Array(String)
  property ruby_code : String
  property manifest : ComponentManifest
  property html : String
  property css : String

  def initialize(@absolute_path : String, @name : String, @imports : Array(String), @ruby_code : String, @manifest : ComponentManifest, @html : String, @css : String)
  end

  def to_s(io : IO)
    io << "MochiComponent(absolute_path: #{absolute_path}, name: #{@name}, ruby_code: #{@ruby_code}, manifest: #{@manifest.tag_name}, html: #{html}, css: #{css})"
  end
end
