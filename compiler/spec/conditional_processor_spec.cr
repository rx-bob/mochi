require "spec"
require "../src/html/conditional_processor"

describe ConditionalProcessor do
  describe ".process" do
    it "processes simple if condition" do
      html = %Q{
        <div>
          {if @show}
            <p>Visible!</p>
          {end}
        </div>
      }

      result = ConditionalProcessor.process(html)

      result.html.should contain("<!--if-anchor-0-->")
      result.conditionals.size.should eq(1)
      result.conditionals[0].condition.should eq("@show")
      result.conditionals[0].id.should eq(0)
    end

    it "processes multiple if conditions" do
      html = %Q{
        <div>
          {if @show}
            <p>First</p>
          {end}
          {if @display}
            <p>Second</p>
          {end}
        </div>
      }

      result = ConditionalProcessor.process(html)

      result.html.should contain("<!--if-anchor-0-->")
      result.html.should contain("<!--if-anchor-1-->")
      # Blocks are sorted by reverse start position, so order may differ
      # Just verify both IDs exist
      ids = result.conditionals.map(&.id).sort
      ids.should eq([0, 1])
    end

    it "processes nested if conditions" do
      html = %Q{
        <div>
          {if @show}
            <div>
              {if @nested}
                <p>Nested content</p>
              {end}
            </div>
          {end}
        </div>
      }

      result = ConditionalProcessor.process(html)

      result.conditionals.size.should eq(2)
      # Should have top-level condition transformed with ID
      result.html.should contain("<!--if-anchor-0-->")
      result.html.should_not contain("<!--if-anchor-1-->") # removed along with block 0 content

      # Blocks are sorted by reverse start position, so verify both IDs exist
      ids = result.conditionals.map(&.id).sort
      ids.should eq([0, 1])
    end

    it "processes condition with comparison operators" do
      html = %Q{
        <div>
          {if @count > 5}
            <p>Greater than 5</p>
          {end}
        </div>
      }

      result = ConditionalProcessor.process(html)

      result.conditionals.size.should eq(1)
      result.conditionals[0].condition.should eq("@count > 5")
      result.conditionals[0].id.should eq(0)
      # No need to escape in data-cond-id, just use ID
      result.html.should contain("<!--if-anchor-0-->")
    end

    it "processes condition with method calls" do
      html = %Q{
        <div>
          {if @items.empty?}
            <p>No items</p>
          {end}
        </div>
      }

      result = ConditionalProcessor.process(html)

      result.conditionals.size.should eq(1)
      result.conditionals[0].condition.should eq("@items.empty?")
    end

    it "handles HTML without conditionals" do
      html = %Q{
        <div>
          <p>No conditionals here</p>
        </div>
      }

      result = ConditionalProcessor.process(html)

      result.conditionals.size.should eq(0)
      result.html.should eq(html)
    end

    it "preserves whitespace and formatting" do
      html = %Q{
        <div class="wrapper">
          {if @show}
            <h1>Title</h1>
            <p>Paragraph</p>
          {end}
        </div>
      }

      result = ConditionalProcessor.process(html)

      # Content is now separated so shouldn't check inside html result any longer. Let's just confirm an anchor is here
      result.html.should contain("<!--if-anchor-0-->")
    end
  end

  describe ".extract_conditionals" do
    it "extracts single conditional block" do
      html = "{if @show}<p>Content</p>{end}"
      blocks = ConditionalProcessor.extract_conditionals(html)

      blocks.size.should eq(1)
      blocks[0].condition.should eq("@show")
      blocks[0].content.should eq("<p>Content</p>")
    end

    it "extracts nested conditional blocks" do
      html = "{if @outer}{if @inner}<p>Nested</p>{end}{end}"
      blocks = ConditionalProcessor.extract_conditionals(html)

      blocks.size.should eq(2)
    end

    it "handles multiple separate blocks" do
      html = "{if @a}<p>A</p>{end}{if @b}<p>B</p>{end}"
      blocks = ConditionalProcessor.extract_conditionals(html)

      blocks.size.should eq(2)
    end

    it "extracts if/elsif/else chains as one block with branches" do
      html = "{if @a}<p>A</p>{elsif @b}<p>B</p>{else}<p>C</p>{end}"
      blocks = ConditionalProcessor.extract_conditionals(html)

      blocks.size.should eq(1)
      block = blocks.first
      block.branches.map(&.condition).should eq(["@a", "@b", nil])
      block.branches.map(&.content).should eq(["<p>A</p>", "<p>B</p>", "<p>C</p>"])
      ConditionalProcessor.process(html).html.should eq("<!--if-anchor-0-->")
    end

    it "links conditionals nested in a branch to that branch" do
      html = "{if @outer}O{if @inner}I{elsif @alt}L{end}X{elsif @other}Y{else}Z{end}"
      blocks = ConditionalProcessor.extract_conditionals(html)

      blocks.size.should eq(2)
      outer = blocks.find { |block| block.id == 0 }.not_nil!
      inner = blocks.find { |block| block.id == 1 }.not_nil!

      outer.branches.size.should eq(3)
      outer.branches[0].children.should eq([inner])
      outer.branches[0].content.should contain("{if @inner}I{elsif @alt}L{end}")
      inner.branches.map(&.condition).should eq(["@inner", "@alt"])
      outer.branches[1].content.should eq("Y")
      outer.branches[2].condition.should be_nil
    end

    it "links three levels of nested conditionals" do
      html = "{if @a}A{if @b}B{if @c}C{end}D{end}E{end}"
      blocks = ConditionalProcessor.extract_conditionals(html)

      blocks.map(&.id).sort.should eq([0, 1, 2])
      outer = blocks.find { |block| block.id == 0 }.not_nil!
      middle = blocks.find { |block| block.id == 1 }.not_nil!
      inner = blocks.find { |block| block.id == 2 }.not_nil!

      outer.branches.first.children.should eq([middle])
      middle.branches.first.children.should eq([inner])
      inner.branches.first.content.should eq("C")
    end

    it "does not treat an each block's end as the conditional end" do
      html = "{if @a}{each @items as item}<p>{item}</p>{end}{end}"
      blocks = ConditionalProcessor.extract_conditionals(html)

      blocks.size.should eq(1)
      blocks.first.branches.first.content.should contain("{each @items as item}")
      blocks.first.branches.first.content.should contain("<p>{item}</p>")
    end
  end

  it "try_match_if_token: one element" do
    html = "{if @abc}<span>Thomas</span>{end}"
    result = ConditionalProcessor.try_match_if_token(html, 0).not_nil!
    puts "result:'#{result}'"
    result.condition.should eq("@abc")
    result.content_start.should eq(9)

    result2 = ConditionalProcessor.try_match_if_token(html, 1)
    puts "result2:'#{result2}'"
    result2.should eq(nil)
  end
end
