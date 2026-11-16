require "path"
require "set"

require "../html/each_processor"
require "../html/template_attributes"
require "../html/template_expression"
require "../tree-sitter/class_extractor"
require "../tree-sitter/property_extractor"
require "../tree-sitter/ruby_parser"
require "../tree-sitter/string_extractor"
require "./config"
require "./diagnostic"
require "./file_discovery"
require "./source_map"

module Lint
  record SourceIssue,
    path : String,
    map : SourceMap,
    start_byte : Int32,
    end_byte : Int32,
    message : String,
    rule : String = ANALYSIS_RULE do
    def diagnostic(severity : Severity) : Diagnostic
      map.diagnostic(@start_byte, @end_byte, severity, @rule, @message)
    end
  end

  record RequireEdge,
    from : String,
    method : String,
    literal : String,
    start_byte : Int32,
    end_byte : Int32,
    resolved_path : String?,
    resolved_absolute : String?,
    problem : String?

  record MethodInfo,
    name : String,
    owner_name : String,
    unit_path : String,
    node : TreeSitter::Node,
    body : TreeSitter::Node?,
    start_byte : Int32,
    end_byte : Int32,
    line : Int32,
    parameters : Array(String),
    singleton : Bool

  class TemplateRow
    getter item_name : String
    getter index_name : String
    getter declared_index : String?
    getter key_expression : String?
    getter start_byte : Int32
    getter end_byte : Int32
    getter content_start_byte : Int32
    getter content_end_byte : Int32
    getter depth : Int32
    getter parent : TemplateRow?

    def initialize(
      @item_name : String,
      @index_name : String,
      @declared_index : String?,
      @key_expression : String?,
      @start_byte : Int32,
      @end_byte : Int32,
      @content_start_byte : Int32,
      @content_end_byte : Int32,
      @depth : Int32,
      @parent : TemplateRow? = nil,
    )
    end

    def scope_names : Array(String)
      names = @parent.try(&.scope_names) || [] of String
      names << @item_name unless names.includes?(@item_name)
      names << @index_name unless names.includes?(@index_name)
      names
    end

    def contains?(byte_offset : Int32) : Bool
      @content_start_byte <= byte_offset && byte_offset < @content_end_byte
    end
  end

  class TemplateView
    getter unit_path : String
    getter map : SourceMap
    getter target : Bool
    getter owner_name : String
    getter method_name : String
    getter method_start_byte : Int32
    getter method_end_byte : Int32
    getter literal_start_byte : Int32
    getter literal_end_byte : Int32
    getter text : String
    getter source_offsets : Array(Int32)
    getter expressions : Array(TemplateExpression)
    getter attributes : Array(TemplateAttribute)
    getter rows : Array(TemplateRow)
    getter issues : Array(SourceIssue)

    def initialize(
      @unit_path : String,
      @map : SourceMap,
      @target : Bool,
      @owner_name : String,
      @method_name : String,
      @method_start_byte : Int32,
      @method_end_byte : Int32,
      @literal_start_byte : Int32,
      @literal_end_byte : Int32,
      @text : String,
      @source_offsets : Array(Int32),
      @expressions : Array(TemplateExpression),
      @attributes : Array(TemplateAttribute),
      @rows : Array(TemplateRow),
      @issues : Array(SourceIssue),
    )
    end

    def target? : Bool
      @target
    end

    def source_byte(template_byte : Int32) : Int32
      return @literal_start_byte if @source_offsets.empty?
      index = template_byte.clamp(0, @source_offsets.size - 1)
      @literal_start_byte + @source_offsets[index]
    end

    def source_range(template_start : Int32, template_end : Int32) : SourceRange
      @map.range(source_byte(template_start), source_byte(template_end))
    end

    def literal_range : SourceRange
      @map.range(@literal_start_byte, @literal_end_byte)
    end

    def attribute_range(attribute : TemplateAttribute) : SourceRange
      source_range(attribute.start, attribute.finish)
    end

    def attribute_value_range(attribute : TemplateAttribute) : SourceRange
      source_range(attribute.value_start, attribute.value_end)
    end

    def scope_at(source_byte : Int32) : Array(String)
      row = @rows
        .select(&.contains?(source_byte))
        .max_by?(&.depth)
      row ? row.scope_names : [] of String
    end

    def self.build(
      unit_path : String,
      map : SourceMap,
      target : Bool,
      owner_name : String,
      method_name : String,
      method_node : TreeSitter::Node,
      literal_start_byte : Int32,
      literal_end_byte : Int32,
      single_quoted : Bool = false,
    ) : TemplateView
      raw_text = map.source.byte_slice(literal_start_byte, literal_end_byte - literal_start_byte)
      text, source_offsets = decode_template(raw_text, single_quoted)
      issues = [] of SourceIssue
      expressions = [] of TemplateExpression
      attributes = [] of TemplateAttribute
      rows = [] of TemplateRow

      parser = TemplateExpressionParser.new
      scan_failed = false
      scanned = begin
        parser.scan(text, "template", [] of String, validate: false)
      rescue ex : TemplateExpressionError
        scan_failed = true
        issues << SourceIssue.new(unit_path, map, literal_start_byte, literal_end_byte, ex.message.to_s)
        [] of TemplateExpression
      end

      blocks = begin
        EachProcessor.extract_each_blocks(text)
      rescue ex : TemplateExpressionError
        issues << SourceIssue.new(unit_path, map, literal_start_byte, literal_end_byte, ex.message.to_s)
        [] of EachBlock
      end
      rows = build_rows(blocks, text, source_offsets, literal_start_byte, unit_path, map, issues)
      unless scan_failed
        if message = structural_block_issue(text)
          issues << SourceIssue.new(unit_path, map, literal_start_byte, literal_end_byte, message)
        end
      end

      scanned.each do |expression|
        next if structural_expression?(expression.source)
        inner_start = template_inner_start(text, expression)
        inner_end = inner_start + expression.source.bytesize
        source_start = literal_start_byte + source_offset(source_offsets, inner_start)
        source_end = literal_start_byte + source_offset(source_offsets, inner_end)
        span = map.template_span(source_start, source_end)
        scoped = TemplateExpression.new(
          expression.source,
          expression.template_start,
          expression.template_end,
          expression.context,
          scope_for_offset(rows, source_start),
          span,
        )
        begin
          parser.validate!(scoped)
          expressions << scoped
        rescue ex : TemplateExpressionError
          issues << SourceIssue.new(unit_path, map, source_start, source_end, ex.message.to_s)
        end
      end

      attributes = if scan_failed
                     [] of TemplateAttribute
                   else
                     begin
                       TemplateAttributes.scan(text, parser)
                     rescue ex : TemplateExpressionError
                       issues << SourceIssue.new(unit_path, map, literal_start_byte, literal_end_byte, ex.message.to_s)
                       [] of TemplateAttribute
                     end
                   end

      unique_issues = [] of SourceIssue
      seen_issues = Set(Tuple(Int32, Int32, String)).new
      issues.each do |issue|
        key = {issue.start_byte, issue.end_byte, issue.message}
        next if seen_issues.includes?(key)
        seen_issues << key
        unique_issues << issue
      end
      unique_issues.sort_by! { |issue| {issue.start_byte, issue.end_byte, issue.message} }

      TemplateView.new(
        unit_path,
        map,
        target,
        owner_name,
        method_name,
        method_node.start_byte,
        method_node.end_byte,
        literal_start_byte,
        literal_end_byte,
        text,
        source_offsets,
        expressions,
        attributes,
        rows,
        unique_issues,
      )
    end

    # Ruby literal escapes are decoded only for the template scanner. The
    # offset table maps every decoded byte back to its authored raw byte, so
    # escaped quotes or newlines cannot shift a later diagnostic.
    private def self.decode_template(raw : String, single_quoted : Bool) : Tuple(String, Array(Int32))
      bytes = [] of UInt8
      offsets = [] of Int32
      index = 0

      append = ->(value : UInt8, source : Int32) do
        bytes << value
        offsets << source
      end

      while index < raw.bytesize
        byte = raw.byte_at(index)
        unless byte == 92_u8 && index + 1 < raw.bytesize
          append.call(byte, index)
          index += 1
          next
        end

        escaped = raw.byte_at(index + 1)
        if single_quoted
          if escaped == 92_u8 || escaped == 39_u8
            append.call(escaped, index + 1)
            index += 2
          else
            append.call(byte, index)
            index += 1
          end
          next
        end

        case escaped
        when 10_u8
          index += 2
        when 13_u8
          index += (index + 2 < raw.bytesize && raw.byte_at(index + 2) == 10_u8) ? 3 : 2
        when 110_u8
          append.call(10_u8, index)
          index += 2
        when 116_u8
          append.call(9_u8, index)
          index += 2
        when 114_u8
          append.call(13_u8, index)
          index += 2
        when 102_u8
          append.call(12_u8, index)
          index += 2
        when 98_u8
          append.call(8_u8, index)
          index += 2
        when 97_u8
          append.call(7_u8, index)
          index += 2
        when 101_u8
          append.call(27_u8, index)
          index += 2
        when 115_u8
          append.call(32_u8, index)
          index += 2
        when 120_u8
          value, consumed = decode_hex(raw, index + 2, 2)
          if consumed > 0
            append.call((value & 0xFF).to_u8, index)
            index += 2 + consumed
          else
            append.call(escaped, index + 1)
            index += 2
          end
        when 117_u8
          value, consumed = decode_unicode(raw, index + 2)
          if consumed > 0 && valid_unicode?(value)
            value.chr.to_s.each_byte { |part| append.call(part, index) }
            index += 2 + consumed
          else
            append.call(escaped, index + 1)
            index += 2
          end
        when 48_u8..55_u8
          value = 0
          consumed = 0
          while consumed < 3 && index + 1 + consumed < raw.bytesize
            digit = raw.byte_at(index + 1 + consumed)
            break unless 48_u8 <= digit <= 55_u8
            value = value * 8 + (digit - 48_u8)
            consumed += 1
          end
          append.call((value & 0xFF).to_u8, index)
          index += 1 + consumed
        else
          append.call(escaped, index + 1)
          index += 2
        end
      end

      offsets << raw.bytesize
      text = String.build do |io|
        bytes.each { |byte| io.write_byte(byte) }
      end
      {text, offsets}
    end

    private def self.valid_unicode?(value : Int32) : Bool
      value >= 0 && value <= 0x10FFFF && !(0xD800 <= value <= 0xDFFF)
    end

    private def self.decode_hex(raw : String, start : Int32, limit : Int32) : Tuple(Int32, Int32)
      value = 0
      consumed = 0
      while consumed < limit && start + consumed < raw.bytesize
        digit = hex_value(raw.byte_at(start + consumed))
        break unless digit
        value = value * 16 + digit
        consumed += 1
      end
      {value, consumed}
    end

    private def self.decode_unicode(raw : String, start : Int32) : Tuple(Int32, Int32)
      if start < raw.bytesize && raw.byte_at(start) == 123_u8
        value = 0
        consumed = 0
        while start + consumed + 1 < raw.bytesize
          byte = raw.byte_at(start + consumed + 1)
          break if byte == 125_u8
          digit = hex_value(byte)
          return {0, 0} unless digit
          value = value * 16 + digit
          consumed += 1
        end
        return {0, 0} if consumed == 0 || start + consumed + 1 >= raw.bytesize
        return {value, consumed + 2}
      end

      value, consumed = decode_hex(raw, start, 4)
      {value, consumed}
    end

    private def self.hex_value(byte : UInt8) : Int32?
      case byte
      when 48_u8..57_u8  then (byte - 48_u8).to_i
      when 65_u8..70_u8  then (byte - 65_u8 + 10).to_i
      when 97_u8..102_u8 then (byte - 97_u8 + 10).to_i
      else                    nil
      end
    end

    private def self.structural_block_issue(text : String) : String?
      depth = 0
      pos = 0
      while pos < text.size
        brace = text.index('{', pos)
        break unless brace

        if text[brace, 5]? == "{end}"
          return "unexpected {end} in template" if depth == 0
          depth -= 1
        elsif text[brace, 6]? == "{else}"
          return "unexpected {else} in template" if depth == 0
        elsif text[brace, 6]? == "{with " || text[brace, 6]? == "{with}"
          return "the {with} directive is not supported; move the lookup into a Ruby helper method and call that method in the template"
        elsif text[brace, 6]? == "{each "
          depth += 1
        elsif text[brace, 4]? == "{if " || text[brace, 8]? == "{unless " || text[brace, 7]? == "{elsif "
          return "unexpected template branch in template" if depth == 0 && text[brace, 7]? == "{elsif "
          depth += 1 unless text[brace, 7]? == "{elsif "
        else
          pos = TemplateExpressionParser.after_placeholder(text, brace)
          next
        end

        pos = TemplateExpressionParser.after_placeholder(text, brace)
      end
      depth > 0 ? "unclosed template block (missing {end})" : nil
    end

    private def self.structural_expression?(source : String) : Bool
      value = source.strip
      return true if value.in?("else", "end")
      ["each ", "if ", "elsif ", "unless ", "with "].any? { |prefix| value.starts_with?(prefix) }
    end

    private def self.template_inner_start(text : String, expression : TemplateExpression) : Int32
      index = expression.template_start + 1
      while index < expression.template_end && TemplateExpressionParser.whitespace?(text.byte_at(index))
        index += 1
      end
      index
    end

    private def self.build_rows(
      blocks : Array(EachBlock),
      text : String,
      source_offsets : Array(Int32),
      literal_start_byte : Int32,
      unit_path : String,
      map : SourceMap,
      issues : Array(SourceIssue),
    ) : Array(TemplateRow)
      rows = [] of TemplateRow
      roots = EachProcessor.roots(blocks)
      roots.each do |block|
        build_row(block, text, source_offsets, literal_start_byte, unit_path, map, rows, issues, nil, 0)
      end
      rows
    end

    private def self.build_row(
      block : EachBlock,
      text : String,
      source_offsets : Array(Int32),
      literal_start_byte : Int32,
      unit_path : String,
      map : SourceMap,
      rows : Array(TemplateRow),
      issues : Array(SourceIssue),
      parent : TemplateRow?,
      depth : Int32,
    ) : Nil
      start_template_byte = TemplateExpressionParser.char_to_byte(text, block.start_pos)
      end_template_byte = TemplateExpressionParser.char_to_byte(text, block.end_pos)
      content_template_byte = TemplateExpressionParser.char_to_byte(text, block.content_start_pos)
      content_end_template_byte = content_template_byte + block.content.bytesize
      start_byte = literal_start_byte + source_offset(source_offsets, start_template_byte)
      end_byte = literal_start_byte + source_offset(source_offsets, end_template_byte)
      content_start = literal_start_byte + source_offset(source_offsets, content_template_byte)
      content_end = literal_start_byte + source_offset(source_offsets, content_end_template_byte)
      loop_def = block.loop_def
      index_name = loop_def.index_name || "index"
      row = TemplateRow.new(
        loop_def.item_name,
        index_name,
        loop_def.index_name,
        loop_def.key_expression,
        start_byte,
        end_byte,
        content_start,
        content_end,
        depth,
        parent,
      )
      rows << row
      block.children.each do |child|
        build_row(child, text, source_offsets, literal_start_byte, unit_path, map, rows, issues, row, depth + 1)
      end
    rescue ex : TemplateExpressionError
      literal_end = literal_start_byte + source_offset(source_offsets, text.bytesize)
      issues << SourceIssue.new(unit_path, map, literal_start_byte, literal_end, ex.message.to_s)
    end

    private def self.source_offset(source_offsets : Array(Int32), template_byte : Int32) : Int32
      source_offsets[template_byte.clamp(0, source_offsets.size - 1)]
    end

    private def self.scope_for_offset(rows : Array(TemplateRow), source_byte : Int32) : Array(String)
      row = rows.select(&.contains?(source_byte)).max_by?(&.depth)
      row ? row.scope_names : [] of String
    end
  end

  class SourceUnit
    getter file : SourceFile
    getter source : String
    getter map : SourceMap
    getter tree : TreeSitter::Tree?
    getter root : TreeSitter::Node?
    getter target : Bool
    getter syntax_ok : Bool
    getter declarations : Array(TreeSitter::ClassDecl)
    getter requires : Array(RequireEdge)
    getter templates : Array(TemplateView)
    getter issues : Array(SourceIssue)

    @closed = false

    def initialize(
      @file : SourceFile,
      @source : String,
      @map : SourceMap,
      @tree : TreeSitter::Tree?,
      @root : TreeSitter::Node?,
      @target : Bool,
      @syntax_ok : Bool,
      @declarations : Array(TreeSitter::ClassDecl),
      @requires : Array(RequireEdge),
      @templates : Array(TemplateView),
      @issues : Array(SourceIssue),
    )
    end

    def target? : Bool
      @target
    end

    def close : Nil
      return if @closed
      @closed = true
      @tree.try(&.close)
    end
  end

  class ClassInfo
    getter qualified_name : String
    getter declarations = [] of TreeSitter::ClassDecl
    getter method_definitions = [] of MethodInfo
    getter methods = {} of String => MethodInfo
    getter singleton_methods = {} of String => MethodInfo
    getter attribute_readers = Set(String).new
    getter props = [] of TreeSitter::PropertyExtractor::PropDeclaration
    getter events = [] of TreeSitter::PropertyExtractor::EventDeclaration
    getter include_names = [] of String
    getter prepend_names = [] of String
    getter extend_names = [] of String
    getter unit_paths = Set(String).new
    property tag_name : String?
    property superclass_name : String?
    property target : Bool
    property open : Bool
    property dynamic_superclass : Bool
    property dynamic_mixins : Bool

    def initialize(@qualified_name : String)
      @target = false
      @open = false
      @dynamic_superclass = false
      @dynamic_mixins = false
      @tag_name = nil
      @superclass_name = nil
    end

    def target? : Bool
      @target
    end

    def open? : Bool
      @open
    end

    def component? : Bool
      !@tag_name.nil?
    end

    def add_declaration(declaration : TreeSitter::ClassDecl, unit_path : String, target : Bool) : Nil
      @declarations << declaration
      @unit_paths << unit_path
      @target = true if target
      @attribute_readers.concat(declaration.attribute_readers)
      @tag_name ||= declaration.tag_name
    end

    def add_method(method : MethodInfo) : Nil
      @method_definitions << method
      if method.singleton
        @singleton_methods[method.name] = method
      else
        @methods[method.name] = method
      end
    end

    def add_prop(prop : TreeSitter::PropertyExtractor::PropDeclaration) : Nil
      @props.reject! { |existing| existing.name == prop.name }
      @props << prop
    end

    def add_event(event : TreeSitter::PropertyExtractor::EventDeclaration) : Nil
      @events.reject! { |existing| existing.name == event.name }
      @events << event
    end

    def method(name : String) : MethodInfo?
      @methods[name]? || @singleton_methods[name]?
    end

    def method_names : Set(String)
      names = Set(String).new
      @methods.each_key { |name| names << name }
      @singleton_methods.each_key { |name| names << name }
      @attribute_readers.each { |name| names << name }
      names
    end

    def method_defined_locally?(name : String) : Bool
      method_names.includes?(name)
    end

    def path : String
      @unit_paths.min? || ""
    end

    def line : Int32
      @declarations.first?.try(&.line) || 1
    end
  end

  class ProjectIndex
    getter config : Config
    getter project_root : String
    getter units : Hash(String, SourceUnit)
    getter selected : Set(String)
    getter classes : Hash(String, ClassInfo)
    getter tags : Hash(String, ClassInfo)
    getter requires : Array(RequireEdge)
    getter issues : Array(SourceIssue)
    getter parse_count : Int32

    @closed = false

    def self.build(
      files : Array(SourceFile),
      config : Config,
      parser : TreeSitter::RubyParser = TreeSitter::RubyParser.new,
    ) : ProjectIndex
      index = new(config, parser)
      index.build(files)
      index
    end

    def initialize(@config : Config, parser : TreeSitter::RubyParser = TreeSitter::RubyParser.new)
      @parser = parser
      @project_root = config.project_root
      @units = {} of String => SourceUnit
      @selected = Set(String).new
      @classes = {} of String => ClassInfo
      @tags = {} of String => ClassInfo
      @requires = [] of RequireEdge
      @issues = [] of SourceIssue
      @parse_count = 0
    end

    def build(files : Array(SourceFile)) : self
      files.each { |file| @selected << file.relative_path }

      queue = files.dup
      cursor = 0
      while cursor < queue.size
        file = queue[cursor]
        cursor += 1
        next if @units.has_key?(file.relative_path)

        unit = parse_unit(file)
        @units[file.relative_path] = unit
        @issues.concat(unit.issues) if unit.target?
        unit.requires.each do |edge|
          next unless absolute = edge.resolved_absolute
          next unless relative = edge.resolved_path
          next if @units.has_key?(relative)
          queue << SourceFile.new(absolute, relative)
        end
      end

      build_inventory
      @requires = @units.values.sort_by(&.file.relative_path).flat_map(&.requires)
      self
    rescue ex
      close
      raise ex
    end

    def unit(relative_path : String) : SourceUnit?
      @units[relative_path]?
    end

    def class_info(qualified_name : String) : ClassInfo?
      @classes[qualified_name]?
    end

    def templates : Array(TemplateView)
      @units.values
        .sort_by(&.file.relative_path)
        .flat_map(&.templates)
    end

    def target_templates : Array(TemplateView)
      templates.select(&.target?)
    end

    def resolve_class(name : String, context : String? = nil) : ClassInfo?
      normalized = normalize_constant(name)
      return @classes[normalized]? if name.starts_with?("::")

      parts = context ? context.split("::") : [] of String
      while true
        candidate = (parts + [normalized]).join("::")
        if found = @classes[candidate]?
          return found
        end
        break if parts.empty?
        parts.pop
      end
      @classes[normalized]?
    end

    def resolve_superclass(info : ClassInfo) : ClassInfo?
      name = info.superclass_name
      return nil unless name
      resolve_class(name, info.qualified_name)
    end

    def resolve_mixins(info : ClassInfo) : Array(ClassInfo)
      (info.include_names + info.prepend_names).compact_map do |name|
        resolve_class(name, info.qualified_name)
      end
    end

    def ancestors(info : ClassInfo) : Array(ClassInfo)
      result = [] of ClassInfo
      seen = Set(String).new
      visit_ancestors(info, result, seen)
      result
    end

    def method_status(info : ClassInfo, name : String) : Bool?
      return true if info.method_defined_locally?(name)
      return nil if info.open?

      ancestors(info).each do |ancestor|
        return true if ancestor.method_defined_locally?(name)
        return nil if ancestor.open?
      end
      false
    end

    def method_defined?(info : ClassInfo, name : String) : Bool?
      method_status(info, name)
    end

    def diagnostics : Array(Diagnostic)
      @issues.compact_map do |issue|
        severity = if issue.rule.in?(SYNTAX_RULE, ANALYSIS_RULE)
                     Severity::Error
                   else
                     settings = @config.rules[issue.rule]?
                     settings ? settings.severity : Severity::Error
                   end
        severity ? issue.diagnostic(severity) : nil
      end.sort_by do |diagnostic|
        {
          diagnostic.path,
          diagnostic.start_byte,
          diagnostic.rule,
          diagnostic.message,
          diagnostic.end_byte,
          diagnostic.severity.label,
          diagnostic.suggestion || "",
        }
      end
    end

    def close : Nil
      return if @closed
      @closed = true
      @units.each_value(&.close)
    end

    private def parse_unit(file : SourceFile) : SourceUnit
      source = File.read(file.absolute_path)
      map = SourceMap.new(source, file.relative_path)
      tree = @parser.parse(source)
      @parse_count += 1
      root = tree.root_node
      target = @selected.includes?(file.relative_path)

      if root.has_error?
        issue = first_syntax_issue(root, map)
        issues = issue ? [issue] : [] of SourceIssue
        return SourceUnit.new(
          file,
          source,
          map,
          tree,
          root,
          target,
          false,
          [] of TreeSitter::ClassDecl,
          [] of RequireEdge,
          [] of TemplateView,
          issues,
        )
      end

      declarations = TreeSitter::ClassExtractor.extract_class_decls(root)
      issues = [] of SourceIssue
      templates = [] of TemplateView
      declarations.each do |declaration|
        body = declaration.node.child_by_field_name("body")
        next unless body
        body.each_named_child do |child|
          next unless child.type == "method"
          name_node = child.child_by_field_name("name")
          next unless name_node && name_node.text == "html"
          info = TreeSitter::StringExtractor.template_content_info(child)
          if info
            view = TemplateView.build(
              file.relative_path,
              map,
              target,
              declaration.qualified_name,
              "html",
              child,
              info[0],
              info[1],
              info[2],
            )
            templates << view
            issues.concat(view.issues) if target
          else
            issues << SourceIssue.new(
              file.relative_path,
              map,
              child.start_byte,
              child.end_byte,
              "html method must return one literal template string",
            ) if target
          end
        end
      end

      SourceUnit.new(
        file,
        source,
        map,
        tree,
        root,
        target,
        true,
        declarations,
        scan_requires(file, root, map),
        templates,
        issues,
      )
    end

    private def scan_requires(file : SourceFile, root : TreeSitter::Node, map : SourceMap) : Array(RequireEdge)
      edges = [] of RequireEdge
      visit_requires(file, root, map, edges)
      edges
    end

    private def visit_requires(
      file : SourceFile,
      node : TreeSitter::Node,
      map : SourceMap,
      edges : Array(RequireEdge),
    ) : Nil
      if node.type.in?("call", "command")
        if edge = require_edge(file, node, map)
          edges << edge
        end
      end

      node.each_named_child do |child|
        visit_requires(file, child, map, edges)
      end
    end

    private def require_edge(file : SourceFile, node : TreeSitter::Node, map : SourceMap) : RequireEdge?
      method_node = node.child_by_field_name(node.type == "call" ? "method" : "name")
      return nil unless method_node
      method = method_node.text
      return nil unless method.in?("require", "require_relative")

      arguments = node.child_by_field_name("arguments")
      return nil unless arguments
      values = [] of TreeSitter::Node
      arguments.each_named_child { |argument| values << argument }
      unless values.size == 1 && values.first.type == "string"
        return RequireEdge.new(
          file.relative_path,
          method,
          values.map(&.text).join(", "),
          node.start_byte,
          node.end_byte,
          nil,
          nil,
          "dynamic require is not supported",
        )
      end

      string_node = values.first
      interpolated = false
      string_node.each_named_child do |child|
        interpolated = true if child.type == "interpolation"
      end
      if interpolated
        return RequireEdge.new(
          file.relative_path,
          method,
          string_node.text,
          node.start_byte,
          node.end_byte,
          nil,
          nil,
          "dynamic require is not supported",
        )
      end

      literal = literal_string(string_node)
      unless literal
        return RequireEdge.new(
          file.relative_path,
          method,
          string_node.text,
          node.start_byte,
          node.end_byte,
          nil,
          nil,
          "dynamic require is not supported",
        )
      end

      resolved_absolute, resolved_path, problem = resolve_require(file, method, literal)
      RequireEdge.new(
        file.relative_path,
        method,
        literal,
        node.start_byte,
        node.end_byte,
        resolved_path,
        resolved_absolute,
        problem,
      )
    end

    private def literal_string(node : TreeSitter::Node) : String?
      range = TreeSitter::StringExtractor.string_content_range(node)
      return nil unless range
      node.source.byte_slice(range[0], range[1] - range[0])
    end

    private def resolve_require(
      file : SourceFile,
      method : String,
      literal : String,
    ) : Tuple(String?, String?, String?)
      base = method == "require_relative" ? File.dirname(file.absolute_path) : @project_root
      candidates = [] of String
      candidates << File.expand_path("#{literal}.rb", base) unless literal.ends_with?(".rb")
      candidates << File.expand_path(literal, base)
      if method == "require"
        candidates << File.expand_path(File.join("lib", "#{literal}.rb"), @project_root) unless literal.ends_with?(".rb")
        candidates << File.expand_path(File.join("lib", literal), @project_root)
      end

      candidates.uniq.each do |candidate|
        next unless File.file?(candidate)
        next if File.symlink?(candidate)
        real = File.realpath(candidate)
        next unless inside?(real, @project_root)
        relative = Path[real].relative_to(@project_root).to_s
        return {real, relative, nil}
      end

      {nil, nil, method == "require_relative" ? "local require not found" : "external or unresolved require"}
    end

    private def build_inventory : Nil
      @units.values.sort_by(&.file.relative_path).each do |unit|
        unit.declarations.each do |declaration|
          info = @classes[declaration.qualified_name]? || ClassInfo.new(declaration.qualified_name)
          @classes[declaration.qualified_name] = info
          info.add_declaration(declaration, unit.file.relative_path, unit.target?)
          collect_class_contract(info, declaration.node, unit)
          attach_tag(info, declaration, unit)
        end
      end

      @classes.each_value do |info|
        info.open = info.dynamic_superclass || info.dynamic_mixins
        info.open ||= info.superclass_name.try { |name| resolve_class(name, info.qualified_name).nil? } || false
        (info.include_names + info.prepend_names).each do |name|
          info.open = true if resolve_class(name, info.qualified_name).nil?
        end
        info.extend_names.each do |name|
          info.open = true if resolve_class(name, info.qualified_name).nil?
        end
      end
    end

    private def collect_class_contract(info : ClassInfo, class_node : TreeSitter::Node, unit : SourceUnit) : Nil
      class_node.child_by_field_name("superclass").try do |superclass|
        if name = constant_name(superclass)
          info.superclass_name ||= name
        else
          info.dynamic_superclass = true
        end
      end

      body = class_node.child_by_field_name("body")
      return unless body

      body.each_named_child do |child|
        if child.type.in?("call", "command")
          collect_mixins(info, child)
        end

        case child.type
        when "method"
          add_method(info, child, unit, singleton: false)
        when "singleton_method"
          add_method(info, child, unit, singleton: true)
        end
      end

      begin
        TreeSitter::PropertyExtractor.extract_props_from_class(class_node, unit.file.relative_path).each do |prop|
          info.add_prop(prop)
        end
      rescue ex : TreeSitter::PropertyExtractor::PropDeclarationError
        add_line_issue(unit, ex.line, ex.message.to_s)
      end

      begin
        TreeSitter::PropertyExtractor.extract_events_from_class(class_node, unit.file.relative_path).each do |event|
          info.add_event(event)
        end
      rescue ex : TreeSitter::PropertyExtractor::EventDeclarationError
        add_line_issue(unit, ex.line, ex.message.to_s)
      end
    end

    private def add_method(info : ClassInfo, method_node : TreeSitter::Node, unit : SourceUnit, singleton : Bool) : Nil
      name_node = method_node.child_by_field_name("name")
      return unless name_node
      body = method_node.child_by_field_name("body")
      parameters = [] of String
      if params_node = method_node.child_by_field_name("parameters")
        params_node.each_named_child { |param| parameters << param.text }
      end
      info.add_method(
        MethodInfo.new(
          name_node.text,
          info.qualified_name,
          unit.file.relative_path,
          method_node,
          body,
          method_node.start_byte,
          method_node.end_byte,
          unit.map.position(method_node.start_byte).line,
          parameters,
          singleton,
        ),
      )
    end

    private def collect_mixins(info : ClassInfo, node : TreeSitter::Node) : Nil
      method_node = node.child_by_field_name(node.type == "call" ? "method" : "name")
      return unless method_node
      target = case method_node.text
               when "include" then info.include_names
               when "prepend" then info.prepend_names
               when "extend"  then info.extend_names
               else                return
               end
      arguments = node.child_by_field_name("arguments")
      return unless arguments
      arguments.each_named_child do |argument|
        if name = constant_name(argument)
          target << name unless target.includes?(name)
        else
          info.dynamic_mixins = true
        end
      end
    end

    private def attach_tag(info : ClassInfo, declaration : TreeSitter::ClassDecl, unit : SourceUnit) : Nil
      tag = declaration.tag_name
      return unless tag

      start_byte, end_byte = tag_location(declaration)
      if !info.tag_name
        info.tag_name = tag
      elsif info.tag_name != tag
        add_issue(unit, start_byte, end_byte, "component '#{info.qualified_name}' declares more than one tag")
      end

      existing = @tags[tag]?
      if existing && existing.qualified_name != info.qualified_name
        add_issue(unit, start_byte, end_byte, "duplicate component tag '#{tag}' also declared by '#{existing.qualified_name}'")
      elsif existing.nil?
        @tags[tag] = info
      end
    end

    private def tag_location(declaration : TreeSitter::ClassDecl) : Tuple(Int32, Int32)
      body = declaration.node.child_by_field_name("body")
      if body
        body.each_named_child do |child|
          next unless child.type == "assignment"
          left = child.child_by_field_name("left")
          if left && left.text == "@tag_name"
            return {child.start_byte, child.end_byte}
          end
        end
      end
      {declaration.start_byte, declaration.end_byte}
    end

    private def visit_ancestors(info : ClassInfo, result : Array(ClassInfo), seen : Set(String)) : Nil
      return if seen.includes?(info.qualified_name)
      seen << info.qualified_name

      if superclass = resolve_superclass(info)
        unless seen.includes?(superclass.qualified_name)
          result << superclass
          visit_ancestors(superclass, result, seen)
        end
      end
      resolve_mixins(info).each do |mixin|
        unless seen.includes?(mixin.qualified_name)
          result << mixin
          visit_ancestors(mixin, result, seen)
        end
      end
    end

    private def first_syntax_issue(root : TreeSitter::Node, map : SourceMap) : SourceIssue?
      node = first_syntax_node(root) || root
      missing = node.type == "ERROR" ? first_missing(node) : (node.missing? ? node : nil)
      location = missing || node
      message = if missing
                  "missing '#{missing.type}'"
                elsif node.type == "ERROR"
                  "Ruby syntax error"
                else
                  "Ruby syntax error"
                end
      SourceIssue.new(
        map.path,
        map,
        location.start_byte,
        location.end_byte,
        message,
        SYNTAX_RULE,
      )
    end

    private def first_syntax_node(node : TreeSitter::Node) : TreeSitter::Node?
      return node if node.type == "ERROR" || node.missing?
      node.each_child do |child|
        if found = first_syntax_node(child)
          return found
        end
      end
      nil
    end

    private def first_missing(node : TreeSitter::Node) : TreeSitter::Node?
      return node if node.missing?
      node.each_child do |child|
        if found = first_missing(child)
          return found
        end
      end
      nil
    end

    private def constant_name(node : TreeSitter::Node) : String?
      case node.type
      when "constant", "scope_resolution"
        node.text
      when "superclass"
        node.each_named_child do |child|
          if name = constant_name(child)
            return name
          end
        end
        nil
      else
        nil
      end
    end

    private def normalize_constant(name : String) : String
      name.lchop("::")
    end

    private def add_line_issue(unit : SourceUnit, line : Int32, message : String) : Nil
      offset = unit.map.line_start(line)
      add_issue(unit, offset, offset, message)
    end

    private def add_issue(unit : SourceUnit, start_byte : Int32, end_byte : Int32, message : String) : Nil
      return unless unit.target?
      @issues << SourceIssue.new(unit.file.relative_path, unit.map, start_byte, end_byte, message)
    end

    private def inside?(path : String, root : String) : Bool
      relative = Path[path].relative_to?(root)
      return false unless relative
      value = relative.to_s
      value == "." || (!Path[value].absolute? && value != ".." && !value.starts_with?("../"))
    end
  end
end
