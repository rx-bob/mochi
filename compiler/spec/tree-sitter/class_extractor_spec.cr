require "spec"
require "../spec_data_loader"
require "../../src/tree-sitter/class_extractor"

def get_class_names(rb_file : String) : Array(String)
  code = SpecDataLoader.load(rb_file)
  puts "code:#{code}"
  names = TreeSitter::ClassExtractor.extract_class_names(code)
  puts "Extracted names: '#{names}'"
  return names
end

def get_class_name(rb_file : String) : String
  code = SpecDataLoader.load(rb_file)
  puts "code:#{code}"
  name = TreeSitter::ClassExtractor.class_name(code)
  puts "Extracted name: '#{name}'"
  return name
end

describe TreeSitter::ClassExtractor do

  it "extracts simple class name" do
    name = get_class_name("treesitter/class_name_simple.rb")
    name.should eq "MyClass"
  end

  it "extracts class name with inheritance" do
    name = get_class_name("treesitter/class_name_with_inheritance.rb")
    name.should eq "MyClass"
  end

  it "extracts namespaced class name" do
    name = get_class_name("treesitter/class_name_namespaced.rb")
    name.should eq "My::Nested::Class"
  end

  it "extracts all class names from file with multiple classes" do
    names = get_class_names("treesitter/class_name_multi_classes.rb")
    names.should eq ["FirstClass", "SecondClass", "ThirdClass"]
  end

  it "extracts class declarations with local ranges and enclosing modules" do
    source = SpecDataLoader.load("treesitter/class_name_multi_classes.rb")
    tree = TreeSitter::RubyParser.new.parse(source)
    declarations = TreeSitter::ClassExtractor.extract_class_decls(tree.root_node).select(&.class?)

    declarations.map(&.name).should eq(["FirstClass", "SecondClass", "ThirdClass"])
    declarations.map(&.line).should eq([1, 4, 8])
    declarations[2].enclosing.should eq(["MyModule"])
    declarations.each do |declaration|
      source.byte_slice(declaration.start_byte, declaration.end_byte - declaration.start_byte).strip.should start_with("class")
    end
  end

  it "scopes tags and methods to the owning class body" do
    source = <<-RUBY
class HelperWithHtml
  def html
    %Q{helper}
  end
end

class TaggedScreen
  @tag_name = "x-tagged-screen"
  def html
    %Q{screen}
  end
end
RUBY
    tree = TreeSitter::RubyParser.new.parse(source)
    declarations = TreeSitter::ClassExtractor.extract_class_decls(tree.root_node)
    helper = declarations.find! { |declaration| declaration.name == "HelperWithHtml" }
    screen = declarations.find! { |declaration| declaration.name == "TaggedScreen" }

    helper.tag_name.should be_nil
    helper.has_html.should be_true
    screen.tag_name.should eq("x-tagged-screen")
    screen.simple_name.should eq("TaggedScreen")
    screen.qualified_name.should eq("TaggedScreen")
  end

  it "distinguishes namespaced and module-wrapped declarations" do
    source = <<-RUBY
class A::B
  @tag_name = "x-a-b"
  def html
    %Q{a}
  end
end

module UI
  class C
    @tag_name = "x-ui-c"
    def html
      %Q{c}
    end
  end
end
RUBY
    tree = TreeSitter::RubyParser.new.parse(source)
    declarations = TreeSitter::ClassExtractor.extract_class_decls(tree.root_node)
    a_b = declarations.find! { |declaration| declaration.name == "A::B" }
    ui_c = declarations.find! { |declaration| declaration.name == "C" }

    a_b.simple_name.should eq("B")
    a_b.qualified_name.should eq("A::B")
    ui_c.enclosing.should eq(["UI"])
    ui_c.qualified_name.should eq("UI::C")
  end

end
