# typed: false
require_relative "../test_helper"
require_relative "../../src/webcomponents/component_generator"

class ComponentGeneratorBindingTest < Minitest::Test
  def test_binding_construction
    binding = ComponentGenerator::Binding.new(
      path: [0, 1, 0],
      type: :text,
      value: "{count}",
      name: nil
    )

    assert_equal [0, 1, 0], binding.path
    assert_equal :text, binding.type
    assert_equal "{count}", binding.value
    assert_nil binding.name
  end

  def test_binding_with_attribute_name
    binding = ComponentGenerator::Binding.new(
      path: [0, 1, 0],
      type: :attr,
      value: "{active}",
      name: "class"
    )

    assert_equal "class", binding.name
    assert_equal :attr, binding.type
  end

  def test_binding_type_error_on_wrong_path
    assert_raises(TypeError) do
      ComponentGenerator::Binding.new(path: "wrong", type: :text, value: "{x}", name: nil)
    end
  end
end

class ComponentGeneratorTraverseTest < Minitest::Test
  def test_text_binding
    html = "<div><span>Count: {count}</span></div>"
    doc = Lexbor::Document.parse(html)
    body = doc.body

    gen = ComponentGenerator.new
    bindings = []
    gen.traverse(body, [], bindings)

    text_bindings = bindings.select { |b| b.type == :text }
    assert_equal 1, text_bindings.size
    b = text_bindings.first
    assert_equal [0, 0, 0], b.path  # body -> div (0) -> span (0) -> text (0)
    assert_equal "{count}", b.value
  end

  def test_html_binding_for_pure_variable_node
    html = "<div>{rendered_svg}</div>"
    doc = Lexbor::Document.parse(html)
    body = doc.body

    gen = ComponentGenerator.new
    bindings = []
    gen.traverse(body, [], bindings)

    html_bindings = bindings.select { |b| b.type == :html }
    assert_equal 1, html_bindings.size
    b = html_bindings.first
    assert_equal [0, 0], b.path  # body -> div (0) -> text (0)
    assert_equal "{rendered_svg}", b.value
  end

  def test_anchor_binding_for_if_comment
    html = "<div>hello<!--if-anchor-0-->world</div>"
    doc = Lexbor::Document.parse(html)
    body = doc.body

    gen = ComponentGenerator.new
    bindings = []
    gen.traverse(body, [], bindings)

    anchor_bindings = bindings.select { |b| b.type == :anchor }
    assert_equal 1, anchor_bindings.size
    b = anchor_bindings.first
    assert_equal [0, 1], b.path  # body -> div (0) -> comment (1)
    assert_equal "if-anchor-0", b.value.strip
  end

  def test_anchor_binding_for_each_comment
    html = "<div>hello<!--each-anchor-1-->world</div>"
    doc = Lexbor::Document.parse(html)
    body = doc.body

    gen = ComponentGenerator.new
    bindings = []
    gen.traverse(body, [], bindings)

    anchor_bindings = bindings.select { |b| b.type == :anchor }
    assert_equal 1, anchor_bindings.size
    b = anchor_bindings.first
    assert_equal [0, 1], b.path  # body -> div (0) -> comment (1)
    assert_equal "each-anchor-1", b.value.strip
  end

  def test_attribute_binding
    html = '<div><p class="{active}">Test</p></div>'
    doc = Lexbor::Document.parse(html)
    body = doc.body

    gen = ComponentGenerator.new
    bindings = []
    gen.traverse(body, [], bindings)

    attr_bindings = bindings.select { |b| b.type == :attr }
    assert_equal 1, attr_bindings.size
    b = attr_bindings.first
    assert_equal [0, 0], b.path  # body -> div (0) -> p (0)
    assert_equal "{active}", b.value
    assert_equal "class", b.name
  end

  def test_bind_attribute_handled_and_removed
    html = '<div bind:class="{active}">hi</div>'
    doc = Lexbor::Document.parse(html)
    body = doc.body

    gen = ComponentGenerator.new
    bindings = []
    gen.traverse(body, [], bindings)

    attr_bindings = bindings.select { |b| b.type == :attr }
    assert_equal 1, attr_bindings.size
    b = attr_bindings.first
    assert_equal "class", b.name
    assert_equal "{active}", b.value

    # The bind: attribute should be removed from the DOM
    node = doc.body.children.first
    attrs = node.attributes
    assert !attrs.key?("bind:class"), "bind:class should be removed"
  end

  def test_onclick_attributes_skipped
    html = '<div onclick="{handleClick}">click me</div>'
    doc = Lexbor::Document.parse(html)
    body = doc.body

    gen = ComponentGenerator.new
    bindings = []
    gen.traverse(body, [], bindings)

    # onclick should not produce a reactive binding
    attr_bindings = bindings.select { |b| b.type == :attr }
    assert_equal 0, attr_bindings.size, "onclick should not create a binding"

    # The onclick attribute should remain in the DOM
    node = doc.body.children.first
    attrs = node.attributes
    assert attrs.key?("onclick"), "onclick should remain in DOM"
  end

  def test_path_includes_text_nodes
    html = "<div>text1<span>{val}</span>text2</div>"
    doc = Lexbor::Document.parse(html)
    body = doc.body

    gen = ComponentGenerator.new
    bindings = []
    gen.traverse(body, [], bindings)

    # Pure variable {val} inside span is :html per Crystal source
    b = bindings.find { |b| b.type == :html }
    assert b, "Should find an html binding"
    # body -> div (0) -> span (1 because text1 is at index 0)
    # -> text (0 inside span)
    assert_equal [0, 1, 0], b.path
  end
end
