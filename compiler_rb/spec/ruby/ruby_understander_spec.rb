# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/ruby/ruby_understander"

FIXTURES_DIR = File.expand_path("../../../compiler/spec_data/ruby", __dir__)

def load_fixture(name)
  File.read(File.join(FIXTURES_DIR, name))
end

def extract_string_from_file(rb_file, method_name)
  code = load_fixture(rb_file)
  class_name = RubyUnderstander.class_name(code)
  methods = RubyUnderstander.extract_method_bodies(code, class_name)
  ruby_def = methods[method_name]
  return nil unless ruby_def
  RubyUnderstander.extract_raw_string_from_def_body(ruby_def.body, method_name)
end

describe RubyUnderstander do
  describe "class_name" do
    it "processes simple component" do
      code = load_fixture("a_layout.rb")
      name = RubyUnderstander.class_name(code)
      _(name).must_equal "ALayout"
    end

    it "handles inheritance" do
      code = <<~RUBY
        class MyClass < ParentClass
        end
      RUBY
      _(RubyUnderstander.class_name(code)).must_equal "MyClass"
    end

    it "handles namespacing" do
      _(RubyUnderstander.class_name("class My::Nested::Class")).must_equal "My::Nested::Class"
    end

    it "handles extra spaces" do
      _(RubyUnderstander.class_name("class   MyClass   ;   end")).must_equal "MyClass"
    end

    it "handles comments" do
      _(RubyUnderstander.class_name("class MyClass # comment")).must_equal "MyClass"
    end

    it "ignores class in strings" do
      _(RubyUnderstander.class_name('"class NotAClass"')).must_equal ""
    end

    it "ignores class in comments" do
      _(RubyUnderstander.class_name("# class InComment ")).must_equal ""
    end

    it "returns first class for nested classes" do
      _(RubyUnderstander.class_name("class A; class B; end; end")).must_equal "A"
    end
  end

  describe "get_cmp_name" do
    it "extracts tag name with double quotes" do
      code = <<~RUBY
        class MyComponent
          @tag_name = "my-component"
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal "my-component"
    end

    it "extracts tag name with single quotes" do
      code = <<~RUBY
        class MyComponent
          @tag_name = 'my-component'
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal "my-component"
    end

    it "extracts tag name with extra whitespace" do
      code = <<~RUBY
        class MyComponent
          @tag_name    =    "my-component"
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal "my-component"
    end

    it "extracts tag name without quotes" do
      code = <<~RUBY
        class MyComponent
          @tag_name = custom-tag
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal "custom-tag"
    end

    it "returns nil when @tag_name not found" do
      code = <<~RUBY
        class MyComponent
          def initialize
          end
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_be_nil
    end

    it "returns first match when multiple @tag_name exist" do
      code = <<~RUBY
        class MyComponent
          @tag_name = "first-component"
          @tag_name = "second-component"
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal "first-component"
    end

    it "extracts tag name from middle of file" do
      code = <<~RUBY
        class MyComponent < BaseComponent
          def initialize
            @foo = "bar"
          end

          @tag_name = "middle-component"

          def render
            # implementation
          end
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal "middle-component"
    end

    it "handles indented @tag_name" do
      code = <<~RUBY
        class MyComponent
            @tag_name = "indented-component"
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal "indented-component"
    end

    it "extracts tag name with hyphens and underscores" do
      code = <<~RUBY
        class MyComponent
          @tag_name = "my-complex_component-name"
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal "my-complex_component-name"
    end

    it "handles empty tag name value" do
      code = <<~RUBY
        class MyComponent
          @tag_name = ""
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal ""
    end

    it "returns nil when @tag_name has no equals sign" do
      code = <<~RUBY
        class MyComponent
          @tag_name
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_be_nil
    end

    it "ignores @tag_name in comments" do
      code = <<~RUBY
        class MyComponent
          # @tag_name = "commented-out"
          @tag_name = "actual-component"
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal "actual-component"
    end

    it "extracts tag name with namespace syntax" do
      code = <<~RUBY
        class MyComponent
          @tag_name = "app:my-component"
        end
      RUBY
      _(RubyUnderstander.get_cmp_name(code, "MyComponent")).must_equal "app:my-component"
    end
  end

  describe "get_imports" do
    it "extracts simple require statements with double quotes" do
      code = load_fixture("imports_simple.rb")
      imports = RubyUnderstander.get_imports(code)
      _(imports).must_equal ["json", "file_utils"]
    end

    it "extracts require statements with single quotes" do
      code = load_fixture("imports_single_quotes.rb")
      imports = RubyUnderstander.get_imports(code)
      _(imports).must_equal ["json", "file_utils"]
    end

    it "extracts mixed quote styles" do
      code = load_fixture("imports_mixed.rb")
      imports = RubyUnderstander.get_imports(code)
      _(imports).must_equal ["json", "file_utils", "http/client"]
    end

    it "extracts relative path requires" do
      code = load_fixture("imports_relative.rb")
      imports = RubyUnderstander.get_imports(code)
      _(imports).must_equal ["./lib/helper", "../utils/parser"]
    end

    it "returns empty array when no requires" do
      code = load_fixture("imports_none.rb")
      imports = RubyUnderstander.get_imports(code)
      _(imports).must_equal []
    end

    it "ignores commented out requires" do
      code = load_fixture("imports_with_comments.rb")
      imports = RubyUnderstander.get_imports(code)
      _(imports).must_equal ["json", "file_utils"]
    end

    it "handles indented requires" do
      code = load_fixture("imports_indented.rb")
      imports = RubyUnderstander.get_imports(code)
      _(imports).must_equal ["json", "file_utils"]
    end
  end

  describe "extract_raw_string_from_def_body" do
    it "extracts string from %Q{} format" do
      result = extract_string_from_file("def_body_uppercase_Q.rb", "html")
      _(result).must_equal "<div>Hello World</div>"
    end

    it "extracts string from %q{} format" do
      result = extract_string_from_file("def_body_lowercase_q.rb", "text")
      _(result).must_equal "Simple text without interpolation"
    end

    it "extracts string from double quotes" do
      result = extract_string_from_file("def_body_double_quotes.rb", "title")
      _(result).must_equal "Welcome to My App"
    end

    it "extracts string from single quotes" do
      result = extract_string_from_file("def_body_single_quotes.rb", "description")
      _(result).must_equal "This is a description"
    end

    it "extracts multiline HTML string" do
      result = extract_string_from_file("def_body_multiline_html.rb", "html")
      expected = "<div class=\"container\">\n    <h1>Title</h1>\n    <p>Content here</p>\n   </div>"
      _(result).must_equal expected
    end

    it "handles tabs in method body" do
      result = extract_string_from_file("def_body_with_tabs.rb", "template")
      _(result).must_equal "<div>With tabs</div>"
    end

    it "extracts plain return without string delimiters" do
      result = extract_string_from_file("def_body_plain_return.rb", "value")
      _(result).must_equal "some_method_call"
    end

    it "extracts strings with multi-byte characters without crashing" do
      result = extract_string_from_file("multi_byte.rb", "html")
      _(result).wont_be_nil
      _(result).must_include "Arrows: ←, →"

      result_css = extract_string_from_file("multi_byte.rb", "css")
      _(result_css).wont_be_nil
      _(result_css).must_include "content: '│';"
    end
  end

  describe "extract_method_bodies" do
    it "extracts simple method with no parameters" do
      code = load_fixture("methods_simple.rb")
      methods = RubyUnderstander.extract_method_bodies(code, "MyComponent")

      _(methods.size).must_equal 1
      _(methods).must_include("render")

      render_method = methods["render"]
      _(render_method.name).must_equal "render"
      _(render_method.class_name).must_equal "MyComponent"
      _(render_method.parameters).must_equal []
    end

    it "extracts method with parameters" do
      code = load_fixture("methods_with_params.rb")
      methods = RubyUnderstander.extract_method_bodies(code, "MyComponent")

      _(methods.size).must_equal 1
      _(methods).must_include("greet")

      greet_method = methods["greet"]
      _(greet_method.name).must_equal "greet"
      _(greet_method.parameters).must_equal ["name", "age"]
    end

    it "extracts multiple methods" do
      code = load_fixture("methods_multiple.rb")
      methods = RubyUnderstander.extract_method_bodies(code, "MyComponent")

      _(methods.size).must_equal 3
      _(methods).must_include("first_method")
      _(methods).must_include("second_method")
      _(methods).must_include("third_method")

      _(methods["first_method"].parameters).must_equal []
      _(methods["second_method"].parameters).must_equal ["arg"]
      _(methods["third_method"].parameters).must_equal []
    end

    it "handles method with nested if statement" do
      code = load_fixture("methods_nested_if.rb")
      methods = RubyUnderstander.extract_method_bodies(code, "MyComponent")

      _(methods.size).must_equal 1
      check_method = methods["check_value"]
      _(check_method.parameters).must_equal ["value"]
      _(check_method.body.size).must_equal 7
      _(check_method.body[0]).must_equal "  def check_value(value)"
      _(check_method.body[6]).must_equal "  end"
    end

    it "handles method with loop" do
      code = load_fixture("methods_with_loop.rb")
      methods = RubyUnderstander.extract_method_bodies(code, "MyComponent")

      _(methods.size).must_equal 1
      iterate_method = methods["iterate"]
      _(iterate_method.parameters).must_equal ["items"]
      _(iterate_method.body.size).must_equal 5
      _(iterate_method.body[0]).must_equal "  def iterate(items)"
      _(iterate_method.body[1]).must_equal "    items.each do |item|"
      _(iterate_method.body[2]).must_equal "      puts item"
      _(iterate_method.body[4]).must_equal "  end"
    end

    it "handles empty method" do
      code = load_fixture("methods_empty.rb")
      methods = RubyUnderstander.extract_method_bodies(code, "MyComponent")

      _(methods.size).must_equal 1
      empty_method = methods["empty_method"]
      _(empty_method.parameters).must_equal []
      _(empty_method.body).must_equal ["  def empty_method", "  end"]
    end

    it "extracts method with default parameters" do
      code = load_fixture("methods_default_params.rb")
      methods = RubyUnderstander.extract_method_bodies(code, "MyComponent")

      _(methods.size).must_equal 1
      configure_method = methods["configure"]
      _(configure_method.parameters).must_equal ["name", "enabled = true"]
    end

    it "returns empty hash when no methods found" do
      code = <<~RUBY
        class MyComponent
          @name = "test"
        end
      RUBY
      methods = RubyUnderstander.extract_method_bodies(code, "MyComponent")
      _(methods.size).must_equal 0
    end

    it "preserves indentation in method body" do
      code = load_fixture("methods_nested_if.rb")
      methods = RubyUnderstander.extract_method_bodies(code, "MyComponent")

      check_method = methods["check_value"]
      _(check_method.body[1]).must_equal "    if value > 0"
      _(check_method.body[2]).must_equal "      puts \"positive\""
    end
  end
end
