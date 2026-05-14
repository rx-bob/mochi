# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/tree_sitter/property_extractor"

FIXTURES_DIR = File.expand_path("../../../compiler/spec_data/treesitter", __dir__)

def load_fixture(name)
  File.read(File.join(FIXTURES_DIR, name))
end

describe TreeSitter::PropertyExtractor do
  describe "extract_property" do
    it "extracts instance variable with double quotes" do
      code = load_fixture("property_simple.rb")
      result = TreeSitter::PropertyExtractor.extract_property(code, "@tag_name")
      _(result).must_equal "my-component"
    end

    it "extracts instance variable with single quotes" do
      code = load_fixture("property_single_quotes.rb")
      result = TreeSitter::PropertyExtractor.extract_property(code, "@tag_name")
      _(result).must_equal "my-component"
    end

    it "returns nil when property not found" do
      code = load_fixture("property_simple.rb")
      result = TreeSitter::PropertyExtractor.extract_property(code, "@missing")
      _(result).must_be_nil
    end

    it "extracts integer value" do
      code = load_fixture("property_integer.rb")
      result = TreeSitter::PropertyExtractor.extract_property(code, "@count")
      _(result).must_equal "42"
    end

    it "extracts boolean value" do
      code = load_fixture("property_boolean.rb")
      result = TreeSitter::PropertyExtractor.extract_property(code, "@enabled")
      _(result).must_equal "true"
    end

    it "extracts constant value" do
      code = load_fixture("property_constant.rb")
      result = TreeSitter::PropertyExtractor.extract_property(code, "@default_value")
      _(result).must_equal "DEFAULT_CONSTANT"
    end

    it "extracts symbol values" do
      code = load_fixture("property_symbol.rb")
      result = TreeSitter::PropertyExtractor.extract_property(code, "@status")
      _(result).must_equal ":active"
    end
  end

  describe "extract_properties" do
    it "extracts multiple instance variables" do
      code = load_fixture("property_multiple.rb")
      properties = TreeSitter::PropertyExtractor.extract_properties(code)
      _(properties.size).must_equal 3
      _(properties[0].name).must_equal "@tag_name"
      _(properties[0].value).must_equal "my-component"
      _(properties[1].name).must_equal "@version"
      _(properties[1].value).must_equal "1.0"
      _(properties[2].name).must_equal "@enabled"
      _(properties[2].value).must_equal "true"
    end

    it "returns empty array when no properties found" do
      code = load_fixture("property_no_instance_vars.rb")
      properties = TreeSitter::PropertyExtractor.extract_properties(code)
      _(properties.size).must_equal 0
    end

    it "extracts properties from nested contexts" do
      code = load_fixture("property_nested.rb")
      properties = TreeSitter::PropertyExtractor.extract_properties(code)
      _(properties.size).must_equal 2
      names = properties.map(&:name)
      _(names).must_include "@outer"
      _(names).must_include "@inner"
    end
  end

  describe "extract_property_names" do
    it "extracts just the property names" do
      code = load_fixture("property_multiple.rb")
      names = TreeSitter::PropertyExtractor.extract_property_names(code)
      _(names).must_equal ["@tag_name", "@version", "@enabled"]
    end
  end

  describe "extract_properties_hash" do
    it "returns properties as a hash" do
      code = load_fixture("property_multiple.rb")
      hash = TreeSitter::PropertyExtractor.extract_properties_hash(code)
      _(hash["@tag_name"]).must_equal "my-component"
      _(hash["@version"]).must_equal "1.0"
    end
  end

  describe "Property struct" do
    it "stores raw value with quotes intact" do
      code = load_fixture("property_simple.rb")
      properties = TreeSitter::PropertyExtractor.extract_properties(code)
      _(properties[0].raw_value).must_equal '"my-component"'
      _(properties[0].value).must_equal "my-component"
    end
  end

  describe "edge cases" do
    it "ignores class variables" do
      code = load_fixture("property_mixed_vars.rb")
      properties = TreeSitter::PropertyExtractor.extract_properties(code)
      _(properties.size).must_equal 1
      _(properties[0].name).must_equal "@instance_var"
    end
  end
end
