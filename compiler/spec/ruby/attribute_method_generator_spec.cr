require "spec"
require "../../src/ruby/attribute_method_generator"
require "../../src/html/attribute_conditional_extractor"

describe AttributeMethodGenerator do
  it "preserves @ivar reads and method calls inside attribute conditionals" do
    result = AttributeConditionalExtractor.process(%Q{<div class="box {if @flag}on {box_class} {@label}{end}">Box</div>})
    conditional = result.conditionals.first

    generated = AttributeMethodGenerator.generate_method(conditional)

    generated.should contain("if @flag")
    generated.should contain(%Q{_parts << "on \#{box_class} \#{@label}"})
    generated.should contain("_parts.join")
    generated.should_not contain(%Q{_parts << "\#{@box_class}"})
  end
end
