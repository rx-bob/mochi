# typed: false
# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "test_helper"
require_relative "../src/initializer"
require_relative "../src/batteries/fragment_loader"

describe Initializer do
  TEST_PROJ = "TestMochiInit"

  before do
    FileUtils.rm_rf("./#{TEST_PROJ}")
  end

  after do
    FileUtils.rm_rf("./#{TEST_PROJ}")
  end

  it "creates project directory and files" do
    out = capture_io do
      Initializer.new(TEST_PROJ)
    end

    assert_includes out[0], "Init '#{TEST_PROJ}'"
    assert Dir.exist?("./#{TEST_PROJ}")
    assert Dir.exist?("./#{TEST_PROJ}/lib")
    assert File.exist?("./#{TEST_PROJ}/Taskfile.yml")
    assert File.exist?("./#{TEST_PROJ}/Gemfile")
    assert File.exist?("./#{TEST_PROJ}/index.html")
    assert File.exist?("./#{TEST_PROJ}/dev_server_config.json")
    assert File.exist?("./#{TEST_PROJ}/README.md")
    assert File.exist?("./#{TEST_PROJ}/lib/MyCounter.rb")
  end

  it "writes Taskfile.yml with correct content" do
    Initializer.new(TEST_PROJ)
    content = File.read("./#{TEST_PROJ}/Taskfile.yml")
    assert_includes content, "version: '3'"
    assert_includes content, "mochi -i \"./\" -o \"./build\""
  end

  it "writes Gemfile with correct content" do
    Initializer.new(TEST_PROJ)
    content = File.read("./#{TEST_PROJ}/Gemfile")
    assert_includes content, 'gem "opal"'
    assert_includes content, "gem 'sorbet-runtime'"
  end

  it "writes dev_server_config.json with correct content" do
    Initializer.new(TEST_PROJ)
    content = File.read("./#{TEST_PROJ}/dev_server_config.json")
    json = JSON.parse(content)
    assert_equal "index.html", json["routes"]["/"]
  end

  it "writes index.html with correct content" do
    Initializer.new(TEST_PROJ)
    content = File.read("./#{TEST_PROJ}/index.html")
    assert_includes content, "<my-counter"
    assert_includes content, "runtime.js"
    assert_includes content, "bundle.js"
    assert_includes content, "Mochi Starter"
  end

  it "writes README.md" do
    Initializer.new(TEST_PROJ)
    content = File.read("./#{TEST_PROJ}/README.md")
    assert_includes content, "Mochi Starter"
    assert_includes content, "https://mochirb.com/docs"
  end

  it "writes MyCounter.rb" do
    Initializer.new(TEST_PROJ)
    content = File.read("./#{TEST_PROJ}/lib/MyCounter.rb")
    refute content.empty?
  end

  it "aborts if project already exists" do
    FileUtils.mkdir_p("./#{TEST_PROJ}")
    out = capture_io do
      Initializer.new(TEST_PROJ)
    end
    assert_includes out[0], "Aborting"
    assert_includes out[0], "already exists"
  end

  it "generator methods return strings" do
    init = Initializer.allocate
    assert_instance_of String, init.generate_taskfile
    assert_instance_of String, init.generate_gemfile
    assert_instance_of String, init.generate_index_html
    assert_instance_of String, init.generate_dev_server_config
    assert_instance_of String, init.generate_readme
    assert_instance_of String, init.generate_my_first_mochi_component
  end
end
