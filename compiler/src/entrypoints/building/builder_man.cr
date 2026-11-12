require "file_utils"
require "random"

class BuilderMan
  STAGED_SOURCE_EXTENSIONS = {".rb", ".css", ".svg", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2"}
  @input_dir : String
  @workspace_dir : String
  @build_id : String
  @excluded_path : String?
  @cleaned : Bool
  @staged_sources : Hash(String, String)

  def initialize(input_dir : String, output_dir : String? = nil)
    expanded_input = File.expand_path(input_dir)
    raise "Input directory does not exist: #{input_dir}" unless Dir.exists?(expanded_input)
    raise "Input directory cannot be a symlink: #{input_dir}" if File.symlink?(expanded_input)

    @input_dir = File.real_path(expanded_input)
    @excluded_path = output_dir.try { |path| BuildPath.canonical(path) }
    @build_id = Random.new.hex(16)
    @workspace_dir = self.class.create_workspace
    @cleaned = false
    @staged_sources = {} of String => String
  end

  def self.create_workspace : String
    10.times do
      path = File.join(Dir.tempdir, "mochi-build-#{Random.new.hex(16)}")
      begin
        Dir.mkdir(path)
        return path
      rescue ex : File::AlreadyExistsError
        next
      end
    end
    raise "Unable to allocate a unique Mochi build workspace"
  end

  def workspace_dir : String
    @workspace_dir
  end

  # Kept as the staging root name used by the compiler pipeline. This is
  # always a unique temporary directory owned by this invocation.
  def build_dir : String
    @workspace_dir
  end

  def ruby_src_dir : String
    File.join(@workspace_dir, "src")
  end

  def pre_tp_dir : String
    File.join(@workspace_dir, "pre_tp")
  end

  def build_id : String
    @build_id
  end

  def input_dir : String
    @input_dir
  end

  def staged_ruby_source_paths : Array(String)
    @staged_sources.keys.sort
  end

  def staged_ruby_source(path : String) : String?
    @staged_sources[path]?
  end

  def staged_ruby_sources : Hash(String, String)
    @staged_sources
  end

  def register_generated_ruby_source(path : String, source : String) : Nil
    File.write(path, source)
    @staged_sources[File.expand_path(path)] = source
  end

  def all_staged_ruby_source : String
    @staged_sources.values.join("\n")
  end

  def copy_ruby_code_to_pre_tp
    Dir.mkdir_p(pre_tp_dir)
    source_lib = File.join(@input_dir, "lib")
    return unless Dir.exists?(source_lib)
    copy_required_sources(source_lib, File.join(pre_tp_dir, "lib"))
  end

  def copy_ruby_code_base
    Dir.mkdir_p(ruby_src_dir)
    copy_tree(pre_tp_dir, ruby_src_dir)
  end

  def cleanup : Nil
    return if @cleaned
    FileUtils.rm_rf(@workspace_dir)
    @cleaned = true
  end

  private def copy_tree(source : String, destination : String) : Nil
    Dir.children(source).each do |entry|
      source_path = File.join(source, entry)
      if excluded_path = @excluded_path
        next if BuildPath.within?(excluded_path, source_path)
      end
      if File.symlink?(source_path)
        raise "Build input contains a symlink; remove it or copy the target into the project: #{source_path}"
      elsif File.directory?(source_path)
        destination_path = File.join(destination, entry)
        Dir.mkdir_p(destination_path)
        copy_tree(source_path, destination_path)
      elsif File.file?(source_path)
        FileUtils.cp(source_path, File.join(destination, entry))
      end
    end
  end

  private def copy_required_sources(source : String, destination : String) : Nil
    Dir.children(source).each do |entry|
      source_path = File.join(source, entry)
      if excluded_path = @excluded_path
        next if BuildPath.within?(excluded_path, source_path)
      end
      if File.symlink?(source_path)
        raise "Build input contains a symlink; remove it or copy the target into the project: #{source_path}"
      elsif File.directory?(source_path)
        copy_required_sources(source_path, File.join(destination, entry))
      elsif File.file?(source_path) && STAGED_SOURCE_EXTENSIONS.includes?(File.extname(entry).downcase)
        Dir.mkdir_p(destination)
        staged_path = File.join(destination, entry)
        if File.extname(entry).downcase == ".rb"
          content = File.read(source_path)
          File.write(staged_path, content)
          @staged_sources[File.expand_path(staged_path)] = content
        else
          FileUtils.cp(source_path, staged_path)
        end
      end
    end
  end
end

module BuildPath
  ROOT_ASSET_EXTENSIONS = {".css", ".svg", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2"}

  def self.canonical(path : String) : String
    expanded = File.expand_path(path)
    raise "Build output cannot be a symlink: #{path}" if File.symlink?(expanded)
    return File.real_path(expanded) if File.exists?(expanded)

    missing = [] of String
    cursor = expanded
    until File.exists?(cursor)
      parent = File.dirname(cursor)
      raise "Unable to resolve build path: #{path}" if parent == cursor
      missing.unshift(File.basename(cursor))
      cursor = parent
    end
    resolved = File.real_path(cursor)
    missing.each { |part| resolved = File.join(resolved, part) }
    resolved
  end

  def self.within?(path : String, parent : String) : Bool
    path == parent || path.starts_with?(parent == "/" ? parent : "#{parent}/")
  end

  def self.validate_input_tree(root : String, excluded_path : String, project_root : Bool = true) : Nil
    Dir.children(root).each do |entry|
      child = File.join(root, entry)
      next if within?(excluded_path, child)
      if project_root
        copied_dir = {"lib", "public", "icons"}.includes?(entry)
        copied_file = entry == "index.html" || ROOT_ASSET_EXTENSIONS.includes?(File.extname(entry).downcase)
        next unless copied_dir || copied_file
      end
      raise "Build input contains a symlink; remove it or copy the target into the project: #{child}" if File.symlink?(child)
      validate_input_tree(child, excluded_path, false) if File.directory?(child)
    end
  end
end
