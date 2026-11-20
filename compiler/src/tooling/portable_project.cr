require "json"

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
  getter fonts : Hash(String, String)

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
    project_root = File.realpath(project_dir)
    fonts.each do |family, asset|
      unless family.matches?(/\A[a-zA-Z][\w-]*\z/) && !family.in?("sans-serif", "monospace")
        raise "#{FILE_NAME}: invalid font family #{family.inspect}"
      end
      parts = asset.split('/')
      unless parts.first? == "public" && parts.size > 1 &&
             parts.none? { |part| part.in?("", ".", "..") || part.includes?('\\') || part.each_char.any?(&.control?) } &&
             File.extname(asset).in?(".woff2", ".otf", ".ttf")
        raise "#{FILE_NAME}: font #{family.inspect} must name a project-relative .woff2, .otf, or .ttf file under public/"
      end
      path = File.join(project_dir, asset)
      unless File.file?(path) && File.realpath(path) == File.join(project_root, asset)
        raise "#{FILE_NAME}: font #{family.inspect} must be a local file at #{asset}"
      end
    end
  end
end
