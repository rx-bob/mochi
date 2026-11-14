require "../html/each_row_template"
require "./inject_utils"
require "./attribute_method_generator"
require "./attribute_hash_generator"
require "./event_action_generator"

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
    arities : Hash(String, Int32) = {} of String => Int32,
  ) : String
    return ruby_code if rows.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    methods_code = generate_all_methods(rows, class_name, arities)
    InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
  end

  def self.generate_all_methods(rows : Array(EachRowTemplate), class_name : String, arities : Hash(String, Int32) = {} of String => Int32) : String
    sections = [] of String
    rows.each do |row|
      sections << generate_rows_method(row)
      row.each_template do |template|
        template.attribute_conditionals.each do |conditional|
          sections << AttributeMethodGenerator.generate_method(
            conditional,
            "__mochi_each_#{template.block_id}_attr_cond_#{conditional.id}",
            template.scope
          )
        end
        template.attribute_hashes.each do |hash|
          sections << AttributeHashGenerator.generate_method(
            hash,
            "__mochi_each_#{template.block_id}_attr_hash_#{hash.id}",
            template.scope
          )
        end
      end
      row.all_events.each { |event| sections << generate_event_wrapper(event, arities) }
    end
    sections.join("\n")
  end

  def self.generated_attribute_method_names(rows : Array(EachRowTemplate)) : Array(String)
    names = [] of String
    rows.each do |root|
      root.each_template do |row|
        row.attribute_conditionals.each do |conditional|
          names << "__mochi_each_#{row.block_id}_attr_cond_#{conditional.id}"
        end
        row.attribute_hashes.each do |hash|
          names << "__mochi_each_#{row.block_id}_attr_hash_#{hash.id}"
        end
      end
    end
    names
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

  def self.generate_event_wrapper(event : EachRowEventDescriptor, arities : Hash(String, Int32) = {} of String => Int32) : String
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
      if event.actions.empty?
        io << "    " << event.handler << "(" << arguments.join(", ") << ")\n"
      else
        io << EventActionGenerator.statements(event.actions, arities, "    ") << "\n"
      end
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
    locals = [row.item_name, row.index_name, "index"].uniq
    lines << "#{indent}(#{row.items_expression} || []).each_with_index do |#{item_param}, #{index_param}; #{locals.join(", ")}|"
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

    lines.concat(render_fragment_statements(row, indent + "  "))

    values = row.bindings.map(&.expression).join(", ")
    child_results = row.children.map { |child| "__mochi_rows_#{child.block_id}" }
    lines << "#{indent}  #{result}.push(["
    lines << "#{indent}    #{item_param},"
    lines << "#{indent}    [#{values}],"
    if row.key_expression || !row.conditionals.empty?
      lines << "#{indent}    [#{child_results.join(", ")}],"
      lines << "#{indent}    (#{row.key_expression || "nil"})#{row.conditionals.empty? ? "" : ","}"
      unless row.conditionals.empty?
        lines << "#{indent}    [#{row.conditionals.map { |c| "__mochi_cond_#{c.id}" }.join(", ")}]"
      end
    else
      lines << "#{indent}    [#{child_results.join(", ")}]"
    end
    lines << "#{indent}  ])"
    lines << "#{indent}end"
    lines.join("\n")
  end

  private def self.render_fragment_statements(fragment : EachRowFragment, indent : String) : Array(String)
    lines = fragment.children.map { |child| render_row_statements(child, indent) }
    fragment.conditionals.each do |conditional|
      name = "__mochi_cond_#{conditional.id}"
      lines << "#{indent}#{name} = nil"
      conditional.branches.each_with_index do |branch, index|
        condition = conditional.conditions[index]
        keyword = index == 0 ? "if" : "elsif"
        lines << (condition ? "#{indent}#{keyword} (#{condition})" : "#{indent}else")
        lines.concat(render_fragment_statements(branch, indent + "  "))
        values = branch.bindings.map(&.expression).join(", ")
        children = branch.children.map { |child| "__mochi_rows_#{child.block_id}" }.join(", ")
        nested = branch.conditionals.map { |child| "__mochi_cond_#{child.id}" }.join(", ")
        lines << "#{indent}  #{name} = [#{index}, [[#{values}], [#{children}], [#{nested}]]]"
      end
      lines << "#{indent}end"
    end
    lines
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
