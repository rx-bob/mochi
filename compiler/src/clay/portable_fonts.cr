require "digest/sha256"
require "./profile"
require "./font_file"

# Resolve the finite family/weight pairs that can reach text leaves. Dynamic
# classes can choose any authored typography rule in their component.
class PortableFonts
  record Selection, family : String, weight : Int32, family_at : String, weight_at : String
  record Face, asset : PortableFace, id : String, metrics : PortableFontFile
  record Run, face : Face, ranges : Array(Tuple(Int32, Int32))
  record Stack, ascent : Float64, descent : Float64, runs : Array(Run)

  getter faces = {} of String => PortableFace
  getter licenses = Set(String).new
  getter stacks = {} of String => Hash(Int32, Stack)
  getter resources = [] of PackageResource

  @aliases = {} of String => String
  @files = {} of PortableFace => Face
  ROOT = "components/fonts"

  def initialize(@project : PortableProject, @project_dir : String, @profile : ClayProfile)
  end

  def resolve(nodes : Array(PortableTemplate::Node)) : Nil
    visit(nodes, Set{Selection.new("sans-serif", 400, "", "")})
  end

  def document_stylesheet(window_css : String) : PackageResource?
    return if @stacks.empty? && window_css.empty?

    css = String.build do |io|
      io << window_css
      @stacks.each do |family, weights|
        identity = weights.map { |weight, stack| {weight, stack.runs.map(&.face.id)} }.to_json
        name = "MochiFont-#{digest(identity)}"
        @aliases[family] = name
        weights.each do |weight, stack|
          stack.runs.each do |run|
            file = font_resource(run.face)
            io << %(@font-face{font-family:#{name};font-style:normal;font-weight:#{weight};)
            io << %(src:url("./#{File.basename(file)}");)
            io << "ascent-override:" << stack.ascent * 100 << "%;"
            io << "descent-override:" << stack.descent * 100 << "%;line-gap-override:0%;unicode-range:"
            run.ranges.each_with_index do |(first, last), index|
              io << "," if index > 0
              io << "U+" << first.to_s(16)
              io << "-" << last.to_s(16) if first != last
            end
            io << "}\n"
          end
        end
      end
    end
    id = "document-style-#{digest(css)}"
    PackageResource.new(id, "document-style", text: css, output_file: "#{ROOT}/#{id}.css")
  end

  def browser_css(css : String, host_layout_css : String) : String
    String.build do |io|
      io << PortableStyles::CSS_RESET << host_layout_css
      io << css
      @profile.styles.rules.each do |rule|
        if family = rule.declarations["font-family"]?
          if alias_name = @aliases[family]?
            generic = family.split(',').last.strip
            family = "#{alias_name},#{generic?(generic) ? generic : "sans-serif"}"
          end
          io << ".#{rule.name}{font-family:#{family}}"
        end
      end
    end
  end

  def native_stacks
    @stacks.transform_values do |weights|
      weights.transform_values do |stack|
        {ascent: stack.ascent, descent: stack.descent, faces: stack.runs.map(&.face.id)}
      end
    end
  end

  private def visit(nodes : Array(PortableTemplate::Node), inherited : Set(Selection)) : Nil
    nodes.each do |node|
      case node
      when PortableTemplate::Element
        states = styles(node, inherited)
        if node.tag.in?("button", "span", "label", "input")
          states.each { |state| resolve(state) }
        else
          visit(node.children, states)
        end
      when PortableTemplate::Conditional
        node.branches.each { |branch| visit(branch, inherited) }
      when PortableTemplate::Rows
        visit(node.children, inherited)
      end
    end
  end

  private def styles(node : PortableTemplate::Element, inherited : Set(Selection)) : Set(Selection)
    parts = node.attributes["class"]? || PortableTemplate::Parts.new
    dynamic = parts.any? { |part| !part.is_a?(String) }
    styles = @profile.styles
    indices = dynamic ? (0...styles.rules.size).to_a : styles.indices(parts.join)
    states = inherited.dup
    indices.each do |index|
      rule = styles.rules[index]
      family = rule.declarations["font-family"]?
      weight = rule.declarations["font-weight"]?.try(&.to_i)
      next unless family || weight
      locations = rule.font_locations
      applied = states.map do |state|
        Selection.new(family || state.family, weight || state.weight,
          locations["font-family"]? || state.family_at, locations["font-weight"]? || state.weight_at)
      end
      states = dynamic ? states.concat(applied) : applied.to_set
    end
    states
  end

  private def resolve(state : Selection) : Nil
    return if generic?(state.family)
    weights = @stacks[state.family] ||= {} of Int32 => Stack
    return if weights.has_key?(state.weight)

    location = state.weight_at.empty? ? state.family_at : state.weight_at
    families = state.family.split(',').map(&.strip)
    candidates = families.compact_map do |family|
      next if generic?(family)
      unless @project.fonts.has_key?(family)
        @profile.font_error(state.family_at, "font family '#{family}' is missing from #{PortableProject::FILE_NAME}")
      end
      if asset = @project.face(family, state.weight, @project_dir)
        font(asset, state.weight)
      end
    end
    first = candidates.first? || @profile.font_error(location, "font stack '#{state.family}' has no declared face for weight #{state.weight}")
    claimed = Set(Int32).new
    runs = candidates.compact_map do |face|
      points = face.metrics.coverage.reject { |point| !claimed.add?(point) }.sort
      unless points.empty?
        @faces[face.id] ||= face.asset
        if license = face.asset.license
          @licenses.add(license)
        end
        Run.new(face, ranges(points))
      end
    end
    weights[state.weight] = Stack.new(first.metrics.ascent, first.metrics.descent, runs)
  end

  private def font(asset : PortableFace, weight : Int32) : Face
    face = @files[asset] ||= begin
      path = File.join(@project_dir, asset.file)
      metrics = PortableFontFile.read(path, "#{PortableProject::FILE_NAME} (#{asset.file})")
      Face.new(asset, "font-#{digest(File.read(path))}", metrics)
    end
    unless face.metrics.weight == weight
      raise "#{PortableProject::FILE_NAME}: #{asset.file} declares weight #{weight}, but the face reports #{face.metrics.weight}"
    end
    face
  end

  private def font_resource(face : Face) : String
    file = "#{ROOT}/#{face.id}#{File.extname(face.asset.file)}"
    unless @resources.any? { |resource| resource.id == face.id }
      @resources << PackageResource.new(face.id, "font", output_file: file, source_path: File.join(@project_dir, face.asset.file))
    end
    if license = face.asset.license
      path = File.join(@project_dir, license)
      id = "font-license-#{digest(File.read(path))}"
      unless @resources.any? { |resource| resource.id == id }
        @resources << PackageResource.new(id, "font-license",
          output_file: "#{ROOT}/#{id}#{File.extname(license)}", source_path: path)
      end
    end
    file
  end

  private def generic?(family : String) : Bool
    family.in?("sans-serif", "monospace")
  end

  private def digest(text : String) : String
    Digest::SHA256.hexdigest(text)[0, 24]
  end

  private def ranges(points : Array(Int32)) : Array(Tuple(Int32, Int32))
    result = [] of Tuple(Int32, Int32)
    points.each do |point|
      if (last = result.last?) && point == last[1] + 1
        result[-1] = {last[0], point}
      else
        result << {point, point}
      end
    end
    result
  end
end
