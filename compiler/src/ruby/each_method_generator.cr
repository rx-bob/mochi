require "../html/each_row_template"
require "./inject_utils"

# Generates the Ruby side of compiled list rows. One getter per root each block
# evaluates every scalar binding and every nested row tree inside the VM. Event
# wrappers evaluate argument expressions in the same lexical scope before
# calling the user's handler.
class EachMethodGenerator
  END_KEYWORD     = "end"
  FALLBACK_OFFSET = 3

  def self.inject_methods_into_class(
    ruby_code : String,
    class_name : String,
    rows : Array(EachRowTemplate),
  ) : String
    return ruby_code if rows.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    methods_code = generate_all_methods(rows, class_name)
    InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
  end

  def self.generate_all_methods(rows : Array(EachRowTemplate), class_name : String) : String
    sections = [] of String
    rows.each do |row|
      sections << generate_rows_method(row)
      row.all_events.each { |event| sections << generate_event_wrapper(event) }
    end
    sections.join("\n")
  end

  def self.generate_rows_method(row : EachRowTemplate) : String
    String.build do |io|
      io << "\n  # auto-generated list row values for block " << row.block_id << "\n"
      io << "  def __mochi_each_" << row.block_id << "_rows\n"
      io << render_row_statements(row, "    ")
      io << "\n"
      io << "    __mochi_rows_" << row.block_id << "\n"
      io << "  end\n"
    end
  end

  def self.generate_event_wrapper(event : EachRowEventDescriptor) : String
    params = [] of String
    assignments = [] of String

    event.scope.each_with_index do |entry, depth|
      item_param = "__mochi_scope_#{depth}_item"
      index_param = "__mochi_scope_#{depth}_index"
      params << item_param << index_param
      assignments << "#{entry.item_name} = #{item_param}"
      assignments << "#{entry.index_name} = #{index_param}" unless entry.index_name == entry.item_name
      unless entry.index_name == "index" || entry.item_name == "index"
        assignments << "index = #{index_param}"
      end
    end
    params << "__event"

    arguments = event.args.map { |argument| ruby_argument(argument) }
    String.build do |io|
      io << "\n  # auto-generated list row event for " << event.event << "\n"
      io << "  def " << event.wrapper_sym << "(" << params.join(", ") << ")\n"
      assignments.each { |line| io << "    " << line << "\n" }
      io << "    " << event.handler << "(" << arguments.join(", ") << ")\n"
      io << "  end\n"
    end
  end

  # The GVM supports `each_with_index` with a block but not the Enumerator
  # returned by a block-less call, so rows accumulate with `push` instead of
  # `each_with_index.map`.
  private def self.render_row_statements(row : EachRowTemplate, indent : String) : String
    item_param = "__mochi_item_#{row.block_id}"
    index_param = "__mochi_index_#{row.block_id}"
    result = "__mochi_rows_#{row.block_id}"
    lines = [] of String

    lines << "#{indent}#{result} = []"
    lines << "#{indent}(#{row.items_expression} || []).each_with_index do |#{item_param}, #{index_param}|"
    lines << "#{indent}  #{row.item_name} = #{item_param}"
    if row.index_name != row.item_name
      lines << "#{indent}  #{row.index_name} = #{index_param}"
    end
    if declared = row.declared_index
      if declared != row.index_name && declared != row.item_name
        lines << "#{indent}  #{declared} = #{index_param}"
      end
    end
    if row.index_name != "index" && row.item_name != "index"
      lines << "#{indent}  index = #{index_param}"
    end

    row.children.each do |child|
      lines << render_row_statements(child, indent + "  ")
    end

    values = row.bindings.map(&.expression).join(", ")
    child_results = row.children.map { |child| "__mochi_rows_#{child.block_id}" }
    lines << "#{indent}  #{result}.push(["
    lines << "#{indent}    #{item_param},"
    lines << "#{indent}    [#{values}],"
    if key = row.key_expression
      lines << "#{indent}    [#{child_results.join(", ")}],"
      lines << "#{indent}    (#{key})"
    else
      lines << "#{indent}    [#{child_results.join(", ")}]"
    end
    lines << "#{indent}  ])"
    lines << "#{indent}end"
    lines.join("\n")
  end

  private def self.ruby_argument(argument : EventArgumentDescriptor) : String
    case argument.kind
    when "event"
      "__event"
    when "literal"
      case argument.literal_type
      when "string"
        literal_string(argument.value || "")
      when "number"
        argument.value || "0"
      when "boolean"
        argument.value == "true" ? "true" : "false"
      else
        "nil"
      end
    when "expr"
      argument.value || "nil"
    else
      raise "unsupported list row event argument kind: #{argument.kind}"
    end
  end

  private def self.literal_string(value : String) : String
    escaped = value.gsub('\\', "\\\\")
      .gsub('"', "\\\"")
      .gsub('#', "\\#")
      .gsub('\n', "\\n")
      .gsub('\r', "\\r")
      .gsub('\t', "\\t")
    "\"#{escaped}\""
  end
end
