require "./inject_utils"
require "../html/attribute_hash_extractor"
require "../html/each_row_template"

class AttributeHashGenerator
  METHOD_PREFIX = "__mochi_attr_hash_"
  END_KEYWORD = "end"
  FALLBACK_OFFSET = 3

  def self.inject_methods_into_class(ruby_code : String, class_name : String, hashes : Array(ExtractedAttributeHash)) : String
    return ruby_code if hashes.empty?

    insertion_point = InjectUtils.find_insertion_point(ruby_code, class_name, END_KEYWORD, FALLBACK_OFFSET)
    return ruby_code unless insertion_point

    methods_code = generate_all_methods(hashes)
    return InjectUtils.insert_code(ruby_code, insertion_point, methods_code)
  end

  def self.generate_all_methods(hashes : Array(ExtractedAttributeHash)) : String
    hashes.map { |cond|
      generate_method(cond)
    }.join("\n")
  end

  def self.generate_method(
    cond : ExtractedAttributeHash,
    method_name : String = "#{METHOD_PREFIX}#{cond.id}",
    scope : Array(EachRowScope) = [] of EachRowScope,
  ) : String
    attr_string = cond.original_string # e.g. {{ "a" => true }}
    
    # Extract the inner part from {{...}}
    inner_hash = attr_string.lchop("{{").rchop("}}").strip
    
    params = [] of String
    assignments = [] of String
    scope.each_with_index do |entry, depth|
      item_param = "__mochi_scope_#{depth}_item"
      index_param = "__mochi_scope_#{depth}_index"
      params << item_param << index_param
      assignments << "    #{entry.item_name} = #{item_param}"
      assignments << "    #{entry.index_name} = #{index_param}" unless entry.index_name == entry.item_name
      unless entry.index_name == "index" || entry.item_name == "index"
        assignments << "    index = #{index_param}"
      end
    end
    prelude = assignments.join("\n")
    signature = params.join(", ")

    <<-RUBY

  # auto-generated attribute hash method
  def #{method_name}(#{signature})
#{prelude}
    _hash = { #{inner_hash} }
    _hash.select { |k, v| v }.keys.join(" ")
  end

RUBY
  end
end
