require "../html/conditional_processor"
require "./inject_utils"

class ConditionalMethodGenerator
  METHOD_PREFIX   = "__mochi_cond_"
  END_KEYWORD     = "end"
  FALLBACK_OFFSET = 3

  # Inject before the class closing 'end'.
  def self.inject_methods_into_class(ruby_code : String, class_name : String, conditionals : Array(ConditionalBlock)) : String
    return ruby_code if conditionals.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    methods_code = generate_all_methods(conditionals, class_name)
    return InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
  end

  # Generate all conditional methods as a single string.
  def self.generate_all_methods(conditionals : Array(ConditionalBlock), class_name : String) : String
    conditionals.map { |block|
      generate_method(block, class_name)
    }.join("\n")
  end

  # Return the first matching branch index, or -1 when no branch matches.
  # The loader uses this integer to mount the corresponding branch template.
  def self.generate_method(block : ConditionalBlock, class_name : String) : String
    method_name = "#{METHOD_PREFIX}#{block.id}"
    branches = block.branches
    body = String.build do |io|
      branches.each_with_index do |branch, index|
        if index == 0
          io << "    if #{branch.condition}\n"
        elsif branch.condition
          io << "    elsif #{branch.condition}\n"
        else
          io << "    else\n"
        end
        io << "      #{index}\n"
      end

      unless branches.any? { |branch| branch.condition.nil? }
        io << "    else\n"
        io << "      -1\n"
      end

      io << "    end\n"
    end

    <<-RUBY

  # auto-generated conditional method
  def #{method_name}
#{body}  end

RUBY
  end
end
