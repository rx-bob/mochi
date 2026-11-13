require "spec"
require "../../src/webcomponents/component_generator"
require "../../src/webcomponents/component_prop_attributes"

describe ComponentPropAttributes do
  it "keeps declared props textual across branches and rows without changing native Boolean attributes" do
    child = ComponentGenerator.new.generate("Child", "child-form", "", "<input>", props: [PropDescriptor.new("required", "boolean", true)])
    html = %(<child-form required="{false}" disabled="{false}"></child-form><input required="{false}">{if @open}<child-form required="{false}"></child-form>{each @rows as row}<CHILD-FORM REQUIRED="{false}"></CHILD-FORM><input required="{false}">{end}{end})
    conditions = ConditionalProcessor.process(html)
    parent = ComponentGenerator.new.generate("Parent", "parent-form", "", conditions.html, conditionals: conditions.conditionals)
    ComponentPropAttributes.apply([parent, child])
    parent.bindings.select { |binding| binding.attr_name == "required" }.map(&.attr_kind).should eq(["text", "boolean"])
    parent.bindings.find! { |binding| binding.attr_name == "disabled" }.attr_kind.should eq("boolean")
    branch = parent.bindings.find! { |binding| binding.kind == "cond" }.branches.first
    branch.bindings.find! { |binding| binding.attr_name == "required" }.attr_kind.should eq("text")
    row = branch.bindings.find! { |binding| binding.kind == "each" }.each_rows.not_nil!
    row.bindings.map(&.attr_kind).should eq(["text", "boolean"])
  end
end
