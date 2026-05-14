# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/data_models/ruby_def"
require_relative "../../src/tree_sitter/string_extractor"
require_relative "../../src/tree_sitter/method_body_extractor"

STRING_EXTRACTOR_FIXTURES_DIR = File.expand_path("../../../compiler/spec_data/treesitter/string_extractor", __dir__)
RUBY_FIXTURES_DIR = File.expand_path("../../../compiler/spec_data/ruby", __dir__)

def extract_string_from_method(fixture_name, method_name)
  code = File.read(File.join(STRING_EXTRACTOR_FIXTURES_DIR, fixture_name))
  class_name = "TestComponent"
  methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, class_name)
  ruby_def = methods[method_name]
  TreeSitter::StringExtractor.extract_raw_string_from_def_body(ruby_def.body, method_name)
end

describe TreeSitter::StringExtractor do
  describe ".extract_raw_string_from_def_body" do
    it "extracts simple double-quoted strings" do
      result = extract_string_from_method("double_quotes.rb", "html")
      _(result).must_equal "<div>Hello</div>"
    end

    it "extracts simple single-quoted strings" do
      result = extract_string_from_method("single_quotes.rb", "css")
      _(result).must_equal "body { color: red; }"
    end

    it "handles %Q{} percent literals" do
      result = extract_string_from_method("percent_q_uppercase.rb", "css")
      _(result).must_include ".component"
      _(result).must_include "color: blue;"
    end

    it "handles %q{} percent literals" do
      result = extract_string_from_method("percent_q_lowercase.rb", "text")
      _(result).must_equal "Simple text"
    end

    it "handles strings with escaped quotes" do
      result = extract_string_from_method("escaped_quotes.rb", "html")
      _(result).must_include "data-value"
    end

    it "handles strings with quotes inside (not escaped)" do
      result = extract_string_from_method("nested_quotes.rb", "html")
      _(result).must_include "class='highlighted'"
    end

    it "handles return statements with strings" do
      result = extract_string_from_method("return_statement.rb", "html")
      _(result).must_equal "<div>Content</div>"
    end

    it "handles reactables array string" do
      result = extract_string_from_method("reactables_array.rb", "reactables")
      _(result).must_equal "['count', 'name']"
    end

    it "handles multi-byte characters without crashing" do
      code = File.read(File.join(RUBY_FIXTURES_DIR, "multi_byte.rb"))
      class_name = "MultiByteComponent"
      methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, class_name)

      html_def = methods["html"]
      html_result = TreeSitter::StringExtractor.extract_raw_string_from_def_body(html_def.body, "html")
      _(html_result).must_include "Arrows: ←, →"
      _(html_result).must_include "Box: ┌─┐"
      _(html_result).must_include "Emoji: 🚀✨"

      css_def = methods["css"]
      css_result = TreeSitter::StringExtractor.extract_raw_string_from_def_body(css_def.body, "css")
      _(css_result).must_include "content: '│';"
    end
  end
end
