# typed: false
require_relative "../test_helper"
require_relative "../../src/tree_sitter/method_body_extractor"

class MethodBodyExtractorTest < Minitest::Test
  FIXTURES_DIR = File.expand_path("../../../compiler/spec_data/ruby", __dir__)

  def test_extracts_simple_method_with_no_parameters
    code = File.read(File.join(FIXTURES_DIR, "methods_simple.rb"))
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 1, methods.size
    assert methods.key?("render")

    render_method = methods["render"]
    assert_equal "render", render_method.name
    assert_equal "MyComponent", render_method.class_name
    assert_equal [], render_method.parameters
    assert_equal ["  def render", "    puts \"Hello\"", "  end"], render_method.body
  end

  def test_extracts_method_with_parameters
    code = File.read(File.join(FIXTURES_DIR, "methods_with_params.rb"))
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 1, methods.size
    assert methods.key?("greet")

    greet_method = methods["greet"]
    assert_equal "greet", greet_method.name
    assert_equal ["name", "age"], greet_method.parameters
  end

  def test_extracts_multiple_methods
    code = File.read(File.join(FIXTURES_DIR, "methods_multiple.rb"))
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 3, methods.size
    assert methods.key?("first_method")
    assert methods.key?("second_method")
    assert methods.key?("third_method")

    assert_equal [], methods["first_method"].parameters
    assert_equal ["arg"], methods["second_method"].parameters
    assert_equal [], methods["third_method"].parameters
  end

  def test_handles_method_with_nested_if_statement
    code = File.read(File.join(FIXTURES_DIR, "methods_nested_if.rb"))
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 1, methods.size
    check_method = methods["check_value"]
    assert_equal ["value"], check_method.parameters
    assert_equal 7, check_method.body.size
    assert_equal "  def check_value(value)", check_method.body[0]
    assert_equal "  end", check_method.body[6]
  end

  def test_handles_method_with_loop
    code = File.read(File.join(FIXTURES_DIR, "methods_with_loop.rb"))
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 1, methods.size
    iterate_method = methods["iterate"]
    assert_equal ["items"], iterate_method.parameters
    assert_equal 5, iterate_method.body.size
    assert_equal "  def iterate(items)", iterate_method.body[0]
    assert_equal "    items.each do |item|", iterate_method.body[1]
    assert_equal "      puts item", iterate_method.body[2]
    assert_equal "  end", iterate_method.body[4]
  end

  def test_handles_empty_method
    code = File.read(File.join(FIXTURES_DIR, "methods_empty.rb"))
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 1, methods.size
    empty_method = methods["empty_method"]
    assert_equal [], empty_method.parameters
    assert_equal ["  def empty_method", "  end"], empty_method.body
  end

  def test_extracts_method_with_default_parameters
    code = File.read(File.join(FIXTURES_DIR, "methods_default_params.rb"))
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 1, methods.size
    configure_method = methods["configure"]
    assert_equal ["name", "enabled = true"], configure_method.parameters
  end

  def test_returns_empty_hash_when_no_methods_found
    code = <<~RUBY
      class MyComponent
        @name = "test"
      end
    RUBY
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 0, methods.size
  end

  def test_preserves_indentation_in_method_body
    code = File.read(File.join(FIXTURES_DIR, "methods_nested_if.rb"))
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    check_method = methods["check_value"]
    assert_equal "    if value > 0", check_method.body[1]
    assert_equal "      puts \"positive\"", check_method.body[2]
  end

  def test_returns_empty_hash_for_non_existent_class
    code = File.read(File.join(FIXTURES_DIR, "methods_simple.rb"))
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "NonExistentClass")

    assert_equal 0, methods.size
  end

  def test_handles_namespaced_class_names
    code = <<~RUBY
      module MyApp
        class MyComponent
          def render
            puts "Hello"
          end
        end
      end
    RUBY
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 1, methods.size
    assert methods.key?("render")
  end

  def test_extracts_method_with_splat_parameters
    code = <<~RUBY
      class MyComponent
        def process(*args)
          puts args
        end
      end
    RUBY
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 1, methods.size
    assert_equal ["*args"], methods["process"].parameters
  end

  def test_extracts_method_with_keyword_parameters
    code = <<~RUBY
      class MyComponent
        def configure(name:, enabled: true)
          @name = name
        end
      end
    RUBY
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 1, methods.size
    configure_method = methods["configure"]
    assert_equal 2, configure_method.parameters.size
  end

  def test_extracts_method_with_block_parameter
    code = <<~RUBY
      class MyComponent
        def execute(&block)
          block.call
        end
      end
    RUBY
    methods = TreeSitter::MethodBodyExtractor.extract_method_bodies(code, "MyComponent")

    assert_equal 1, methods.size
    assert_equal ["&block"], methods["execute"].parameters
  end
end
