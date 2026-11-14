# One immutable build artifact referenced by the component manifest. Style
# resources carry their text; icon resources carry a copied file. Resource IDs
# are stable so a later lazy package graph can deduplicate and own them
# without adding a second loader.
struct PackageResource
  getter id : String
  getter kind : String
  getter text : String?
  getter output_file : String?
  getter source_path : String?

  def initialize(
    @id : String,
    @kind : String,
    @text : String? = nil,
    @output_file : String? = nil,
    @source_path : String? = nil,
  )
  end
end

# Selects SVG files named by the application source. A component asks for an
# icon with MochiIcons.icon("name"); names stored in application data also count
# because they appear as source literals. Unrequested files in icons/ stay out
# of the emitted package.
class IconAssetCollector
  ICON_NAME      = /[a-z0-9][a-z0-9-]*/
  EXPLICIT_ICON  = /MochiIcons\.icon\s*\(\s*(?:"([a-z0-9][a-z0-9-]*)"|'([a-z0-9][a-z0-9-]*)'|:([a-z_][a-z0-9_-]*))/
  HTML_ICON_ATTR = /\bicon\s*=\s*["']([a-z0-9][a-z0-9-]*)["']/
  QUOTED_NAME    = /["']([a-z0-9][a-z0-9-]*)["']/

  @icon_dir : String?
  @available : Hash(String, String)
  @requested : Set(String)
  @sources : Hash(String, String)

  def initialize(icon_dir : String?)
    @icon_dir = icon_dir
    @available = {} of String => String
    @requested = Set(String).new
    @sources = {} of String => String

    if icon_dir && File.directory?(icon_dir)
      Dir.glob(File.join(icon_dir, "*.svg")).sort.each do |path|
        name = File.basename(path, ".svg")
        @available[name] = path if name.matches?(ICON_NAME)
      end
    end
  end

  def collect(
    source_paths : Array(String),
    cached_sources : Hash(String, String) = {} of String => String,
  ) : Array(PackageResource)
    source_paths.sort.each do |path|
      next unless File.file?(path)
      @sources[path] = cached_sources[path]? || File.read(path)
    end

    @sources.each do |path, text|
      scan_explicit_icons(path, text)
      scan_referenced_names(path, text)
      scan_html_icon_attributes(path, text) if path.ends_with?(".html") || path.ends_with?(".htm")
    end

    @requested.to_a.sort.map do |name|
      source = @available[name]
      PackageResource.new(
        "icon:#{name}",
        "icon",
        output_file: "mochi-icons/#{name}.svg",
        source_path: source
      )
    end
  end

  private def scan_explicit_icons(path : String, text : String) : Nil
    text.scan(EXPLICIT_ICON) do |match|
      name = match[1]? || match[2]? || match[3]?
      next unless name
      next if @available.has_key?(name)

      location = "#{path}:#{line_at(text, match.byte_begin(0))}"
      icon_dir = @icon_dir
      if icon_dir.nil? || !File.directory?(icon_dir)
        raise "Component icon MochiIcons.icon(#{name.inspect}) at #{location} requires an icons/ directory with #{name}.svg"
      end
      raise "Component icon MochiIcons.icon(#{name.inspect}) at #{location} has no build asset #{File.join(icon_dir, "#{name}.svg")}"
    end
  end

  # Application data such as queue rows can carry a dynamic icon name. If that
  # name is a source literal and a matching build asset exists, include it.
  private def scan_referenced_names(path : String, text : String) : Nil
    return if @available.empty?

    text.scan(QUOTED_NAME) do |match|
      name = match[1]?
      @requested << name if name && @available.has_key?(name)
    end
  end

  private def scan_html_icon_attributes(path : String, text : String) : Nil
    return if @available.empty?

    text.scan(HTML_ICON_ATTR) do |match|
      name = match[1]?
      @requested << name if name && @available.has_key?(name)
    end
  end

  private def line_at(text : String, byte_index : Int32) : Int32
    text.byte_slice(0, byte_index).count('\n') + 1
  end
end
