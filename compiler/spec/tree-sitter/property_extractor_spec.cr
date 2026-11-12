require "spec"
require "../spec_data_loader"
require "../../src/tree-sitter/property_extractor"

def get_property(rb_file : String, property_name : String) : String?
  code = SpecDataLoader.load(rb_file)
  TreeSitter::PropertyExtractor.extract_property(code, property_name)
end

def get_properties(rb_file : String) : Array(TreeSitter::PropertyExtractor::Property)
  code = SpecDataLoader.load(rb_file)
  TreeSitter::PropertyExtractor.extract_properties(code)
end

def get_property_names(rb_file : String) : Array(String)
  code = SpecDataLoader.load(rb_file)
  TreeSitter::PropertyExtractor.extract_property_names(code)
end

def get_properties_hash(rb_file : String) : Hash(String, String)
  code = SpecDataLoader.load(rb_file)
  TreeSitter::PropertyExtractor.extract_properties_hash(code)
end

describe TreeSitter::PropertyExtractor do

  describe "extract_property" do
    it "extracts instance variable with double quotes" do
      result = get_property("treesitter/property_simple.rb", "@tag_name")
      result.should eq "my-component"
    end

    it "extracts instance variable with single quotes" do
      result = get_property("treesitter/property_single_quotes.rb", "@tag_name")
      result.should eq "my-component"
    end

    it "returns nil when property not found" do
      result = get_property("treesitter/property_simple.rb", "@missing")
      result.should be_nil
    end

    it "extracts integer value" do
      result = get_property("treesitter/property_integer.rb", "@count")
      result.should eq "42"
    end

    it "extracts boolean value" do
      result = get_property("treesitter/property_boolean.rb", "@enabled")
      result.should eq "true"
    end

    it "extracts constant value" do
      result = get_property("treesitter/property_constant.rb", "@default_value")
      result.should eq "DEFAULT_CONSTANT"
    end

    it "extracts symbol values" do
      result = get_property("treesitter/property_symbol.rb", "@status")
      result.should eq ":active"
    end
  end

  describe "extract_properties" do
    it "extracts multiple instance variables" do
      properties = get_properties("treesitter/property_multiple.rb")
      properties.size.should eq 3
      properties[0].name.should eq "@tag_name"
      properties[0].value.should eq "my-component"
      properties[1].name.should eq "@version"
      properties[1].value.should eq "1.0"
      properties[2].name.should eq "@enabled"
      properties[2].value.should eq "true"
    end

    it "returns empty array when no properties found" do
      properties = get_properties("treesitter/property_no_instance_vars.rb")
      properties.size.should eq 0
    end

    it "extracts properties from nested contexts" do
      properties = get_properties("treesitter/property_nested.rb")
      properties.size.should eq 2
      names = properties.map(&.name)
      names.should contain "@outer"
      names.should contain "@inner"
    end
  end

  describe "extract_property_names" do
    it "extracts just the property names" do
      names = get_property_names("treesitter/property_multiple.rb")
      names.should eq ["@tag_name", "@version", "@enabled"]
    end
  end

  describe "extract_properties_hash" do
    it "returns properties as a hash" do
      hash = get_properties_hash("treesitter/property_multiple.rb")
      hash["@tag_name"].should eq "my-component"
      hash["@version"].should eq "1.0"
    end
  end

  describe "Property struct" do
    it "stores raw value with quotes intact" do
      properties = get_properties("treesitter/property_simple.rb")
      properties[0].raw_value.should eq "\"my-component\""
      properties[0].value.should eq "my-component"
    end
  end

  describe "edge cases" do
    it "ignores class variables" do
      properties = get_properties("treesitter/property_mixed_vars.rb")
      properties.size.should eq 1
      properties[0].name.should eq "@instance_var"
    end
  end

  describe "extract_props" do
    it "reads typed declarations, required flags, defaults, and source lines" do
      source = <<-RUBY
class ChildBadge
  @tag_name = "child-badge"
  prop :label, String, required: true
  prop :count, Integer, default: 0
  prop :rows, Array, default: []
  prop :note, String, default: nil
end
RUBY

      props = TreeSitter::PropertyExtractor.extract_props(source, "child.rb")
      props.size.should eq 4
      props[0].name.should eq "label"
      props[0].type.should eq "string"
      props[0].required.should be_true
      props[0].default_code.should be_nil
      props[0].line.should eq 3
      props[1].type.should eq "integer"
      props[1].default_code.should eq "0"
      props[2].type.should eq "array"
      props[2].default_code.should eq "[]"
      props[3].default_code.should eq "nil"
    end

    it "accepts float declarations and float defaults" do
      source = <<-RUBY
class Meter
  @tag_name = "meter"
  prop :ratio, Float, default: 0.5
  prop :height, Float
end
RUBY

      props = TreeSitter::PropertyExtractor.extract_props(source, "meter.rb")
      props.size.should eq 2
      props[0].type.should eq "float"
      props[0].default_code.should eq "0.5"
      props[1].type.should eq "float"
      props[1].default_code.should be_nil
    end

    it "rejects integer defaults for float declarations" do
      source = <<-RUBY
class Meter
  prop :ratio, Float, default: 1
end
RUBY

      expect_raises(TreeSitter::PropertyExtractor::PropDeclarationError, /does not match float/) do
        TreeSitter::PropertyExtractor.extract_props(source, "meter.rb")
      end
    end

    it "ignores prop declarations in nested classes" do
      source = <<-RUBY
class Outer
  @tag_name = "outer"
  prop :label, String

  class Inner
    prop :inner_label, String
  end
end
RUBY

      props = TreeSitter::PropertyExtractor.extract_props(source)
      props.map(&.name).should eq ["label"]
    end

    it "ignores a receiver-qualified prop call" do
      source = <<-RUBY
class Outer
  @tag_name = "outer"
  Schema.prop :label, String
end
RUBY

      props = TreeSitter::PropertyExtractor.extract_props(source)
      props.should be_empty
    end

    it "rejects unknown types with a source line" do
      source = <<-RUBY
class Badge
  prop :label, Symbol
end
RUBY

      expect_raises(TreeSitter::PropertyExtractor::PropDeclarationError, /unsupported type Symbol/) do
        TreeSitter::PropertyExtractor.extract_props(source, "badge.rb")
      end
    end

    it "rejects required props with defaults" do
      source = <<-RUBY
class Badge
  prop :label, String, required: true, default: "x"
end
RUBY

      expect_raises(TreeSitter::PropertyExtractor::PropDeclarationError, /cannot be required/) do
        TreeSitter::PropertyExtractor.extract_props(source, "badge.rb")
      end
    end

    it "rejects duplicate declarations" do
      source = <<-RUBY
class Badge
  prop :label, String
  prop :label, Integer
end
RUBY

      expect_raises(TreeSitter::PropertyExtractor::PropDeclarationError, /declared twice/) do
        TreeSitter::PropertyExtractor.extract_props(source, "badge.rb")
      end
    end

    it "rejects a default whose literal type does not match" do
      source = <<-RUBY
class Badge
  prop :count, Integer, default: "zero"
end
RUBY

      expect_raises(TreeSitter::PropertyExtractor::PropDeclarationError, /does not match integer/) do
        TreeSitter::PropertyExtractor.extract_props(source, "badge.rb")
      end
    end

    it "rejects invalid names and unknown options" do
      expect_raises(TreeSitter::PropertyExtractor::PropDeclarationError, /lower_snake_case/) do
        TreeSitter::PropertyExtractor.extract_props("class Badge\n  prop :\"bad-name\", String\nend", "badge.rb")
      end

      expect_raises(TreeSitter::PropertyExtractor::PropDeclarationError, /unknown option/) do
        TreeSitter::PropertyExtractor.extract_props("class Badge\n  prop :label, String, value: 1\nend", "badge.rb")
      end
    end
  end
end
