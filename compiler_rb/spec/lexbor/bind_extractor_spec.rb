# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require "lexbor/bind_extractor"

describe BindExtractor do
  it "get_key_no_prefix" do
    key_no_prefix = BindExtractor.get_key_no_prefix("bind:href")
    _(key_no_prefix).must_equal "href"
  end

  it "get_bind_key" do
    key_no_prefix = BindExtractor.get_bind_key("count")
    _(key_no_prefix).must_equal "count"
    key_no_prefix_2 = BindExtractor.get_bind_key("{count}")
    _(key_no_prefix_2).must_equal "count"
  end

  it "bind extractions: simple" do
    result = BindExtractor.extract("<a bind:href=\"abc\"></a>")
    _(result.html).must_equal "<a href=\"abc\"></a>"
    _(result.bindings).must_equal({"abc" => "href"})
  end

  it "bind extractions: nested" do
    result = BindExtractor.extract("<a bind:href='abc'><div bind:airplane=''></div></a>")
    _(result.html).must_equal "<a href=\"abc\"><div airplane=\"\"></div></a>"
    _(result.bindings).must_equal({"abc" => "href"})
  end

  it "bind extractions: multiple binds" do
    result = BindExtractor.extract("<a bind:href='abc' bind:text='def'></a>")
    _(result.html).must_equal "<a href=\"abc\" text=\"def\"></a>"
    _(result.bindings).must_equal({"abc" => "href", "def" => "text"})
  end

  it "bind extractions: big" do
    result = BindExtractor.extract("<div class=\"wrapper\">
        <h1>Count123: {count}</h1>
        <h2>Modifications: {modifications}</h2>
        {if @count > 5}
          <p style=\"border-radius: 8px;\">Count is greater than 5!</p>
        {end}
        {if @count < 0}
          <p style=\"border-radius: 8px;\">Count is negative!</p>
        {end}
        <button onclick={increment}>Increment</button>
        <button onclick={decrement}>Decrement</button>
        <plus-five bind:pfcount=\"{count}\"></plus-five>
        <input value={count} onchange={input_changed} type=\"text\"></input>
      </div>")
    _(result.html).must_equal "<div class=\"wrapper\">\n        <h1>Count123: {count}</h1>\n        <h2>Modifications: {modifications}</h2>\n        {if @count &gt; 5}\n          <p style=\"border-radius: 8px;\">Count is greater than 5!</p>\n        {end}\n        {if @count &lt; 0}\n          <p style=\"border-radius: 8px;\">Count is negative!</p>\n        {end}\n        <button onclick=\"{increment}\">Increment</button>\n        <button onclick=\"{decrement}\">Decrement</button>\n        <plus-five pfcount=\"{count}\"></plus-five>\n        <input value=\"{count}\" onchange=\"{input_changed}\" type=\"text\">\n      </div>"
    _(result.bindings).must_equal({"count" => "pfcount"})
  end
end
