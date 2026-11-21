require "json"

struct PortableFace
  include JSON::Serializable
  include JSON::Serializable::Strict
  getter file : String
  getter license : String?

  def initialize(@file, @license = nil)
  end
end

alias PortableFontDeclaration = String | Hash(String, PortableFace)

struct PortableWindow
  include JSON::Serializable
  include JSON::Serializable::Strict

  getter inset : Int32 = 0
  getter max_width : Int32?

  def host_css : String
    ":host{display:block;box-sizing:border-box;margin:#{inset}px;" +
      "width:max(0px,calc(100% - #{inset * 2}px));max-width:#{max_width.try { |width| "#{width}px" } || "none"}}"
  end

  def validate : Nil
    unless (0..9999).includes?(inset) && max_width.try { |width| (1..9999).includes?(width) } != false
      raise "#{PortableProject::FILE_NAME}: window inset must be 0–9999 and max_width must be 1–9999 logical pixels"
    end
  end
end

# A project with this declaration targets the shared DOM and desktop profile.
struct PortableProject
  FILE_NAME = "mochi-portable.json"
  VERSION   = 1

  include JSON::Serializable
  include JSON::Serializable::Strict

  getter version : Int32
  getter root : String
  getter app_id : String
  getter display_name : String
  getter fonts : Hash(String, PortableFontDeclaration)
  getter window : PortableWindow?

  def self.declaration_path(project_dir : String) : String?
    path = File.join(project_dir, FILE_NAME)
    raise "#{FILE_NAME}: declaration must be a local file" if File.symlink?(path)
    return unless File.exists?(path)
    raise "#{FILE_NAME}: declaration must be a local file" unless File.file?(path)
    path
  end

  def self.read(project_dir : String) : self?
    return unless path = declaration_path(project_dir)
    begin
      project = from_json(File.read(path))
    rescue ex : JSON::Error | IO::Error
      raise "#{FILE_NAME}: #{ex.message}"
    end
    project.validate(project_dir)
    project
  end

  protected def validate(project_dir : String) : Nil
    raise "#{FILE_NAME}: unsupported version #{version}; expected #{VERSION}" unless version == VERSION
    unless root.matches?(/\A[a-z][a-z0-9]*(?:-[a-z0-9]+)+\z/)
      raise "#{FILE_NAME}: invalid root tag #{root.inspect}"
    end
    unless app_id.matches?(/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/)
      raise "#{FILE_NAME}: app_id must be a reverse DNS identifier"
    end
    if display_name.strip.empty? || display_name.each_char.any?(&.control?)
      raise "#{FILE_NAME}: display_name must be nonempty text"
    end
    window.try(&.validate)
    project_root = File.realpath(project_dir)
    fonts.each do |family, value|
      unless family.matches?(/\A[a-zA-Z][\w-]*\z/) && !family.downcase.in?("sans-serif", "monospace")
        raise "#{FILE_NAME}: invalid font family #{family.inspect}"
      end
      faces = value.is_a?(String) ? {"400" => PortableFace.new(value)} : value
      raise "#{FILE_NAME}: font #{family.inspect} must declare at least one weight" if faces.empty?
      faces.each do |weight, face|
        unless weight.matches?(/\A[1-9]00\z/)
          raise "#{FILE_NAME}: invalid font weight #{weight.inspect} for #{family.inspect}"
        end
        validate_font_asset(project_root, family, face.file, {".woff2", ".otf", ".ttf"})
        if license = face.license
          validate_font_asset(project_root, family, license, {".txt", ".md"})
        end
      end
    end
  end

  def bundle_name : String
    basename = display_name.gsub(/[\/:]/, "-").strip.lstrip('.')
    basename = "Mochi" if basename.empty?
    "#{basename}.app"
  end

  def face(family : String, weight : Int32, project_dir : String) : PortableFace?
    value = fonts[family]?
    if value.is_a?(String)
      return unless weight == 400
      license = File.join(File.dirname(value), "OFL.txt")
      PortableFace.new(value, File.file?(File.join(project_dir, license)) ? license : nil)
    elsif value
      value[weight.to_s]?
    end
  end

  def managed_font_assets(project_dir : String) : Set(String)
    fonts.flat_map do |family, value|
      weights = value.is_a?(String) ? ["400"] : value.keys
      weights.flat_map do |weight|
        asset = face(family, weight.to_i, project_dir).not_nil!
        [asset.file, asset.license].compact
      end
    end.to_set
  end

  private def validate_font_asset(project_root, family, asset, extensions) : Nil
    parts = asset.split('/')
    unless parts.first? == "public" && parts.size > 1 &&
           parts.none? { |part| part.in?("", ".", "..") || part.includes?('\\') || part.each_char.any?(&.control?) } &&
           extensions.includes?(File.extname(asset))
      raise "#{FILE_NAME}: font #{family.inspect} must name a project-relative #{extensions.join(", ")} file under public/"
    end
    path = File.join(project_root, asset)
    unless File.file?(path) && File.realpath(path) == path
      raise "#{FILE_NAME}: font #{family.inspect} must be a local file at #{asset}"
    end
  end
end
