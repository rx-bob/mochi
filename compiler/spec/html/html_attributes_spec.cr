require "spec"
require "../../src/html/html_attributes"

describe HtmlAttributes do
  it "classifies HTML boolean attributes" do
    HtmlAttributes.kind("disabled").should eq("boolean")
    HtmlAttributes.kind("checked").should eq("boolean")
    HtmlAttributes.kind("hidden").should eq("boolean")
    HtmlAttributes.kind("open").should eq("boolean")
  end

  it "keeps aria, data, enumerated, and ordinary attributes textual" do
    HtmlAttributes.kind("aria-expanded").should eq("text")
    HtmlAttributes.kind("aria-hidden").should eq("text")
    HtmlAttributes.kind("data-count").should eq("text")
    HtmlAttributes.kind("class").should eq("text")
    HtmlAttributes.kind("title").should eq("text")
    HtmlAttributes.kind("value").should eq("text")
    HtmlAttributes.kind("spellcheck").should eq("text")
    HtmlAttributes.kind("draggable").should eq("text")
  end

  it "classifies names case-insensitively" do
    HtmlAttributes.kind("DISABLED").should eq("boolean")
    HtmlAttributes.kind("Aria-Expanded").should eq("text")
  end
end
