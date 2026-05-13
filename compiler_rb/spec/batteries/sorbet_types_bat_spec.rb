# typed: false
require_relative "../test_helper"
require_relative "../../src/batteries/sorbet_types_bat"

class SorbetTypesBatTest < Minitest::Test
  def test_generate_creates_browser_rb
    Dir.mktmpdir do |dir|
      SorbetTypesBat.generate(dir)

      assert File.exist?("#{dir}/lib/sorbet-types/browser.rb"), "Expected browser.rb to be created"
    end
  end

  def test_generate_creates_sorbet_rb
    Dir.mktmpdir do |dir|
      SorbetTypesBat.generate(dir)

      assert File.exist?("#{dir}/lib/sorbet-types/sorbet.rb"), "Expected sorbet.rb to be created"
    end
  end

  def test_generate_browser_types_contains_browser_module
    output = SorbetTypesBat.generate_browser_types

    assert_includes output, "module Browser"
  end

  def test_generate_browser_types_contains_http_module
    output = SorbetTypesBat.generate_browser_types

    assert_includes output, "module HTTP"
    assert_includes output, "def self.get(url)"
    assert_includes output, "def self.post(url, payload)"
  end

  def test_generate_opal_types_contains_t_module
    output = SorbetTypesBat.generate_opal_types

    assert_includes output, "module T"
  end

  def test_generate_opal_types_contains_sig_module
    output = SorbetTypesBat.generate_opal_types

    assert_includes output, "module Sig"
    assert_includes output, "def sig(&block)"
    assert_includes output, "def returns(type)"
    assert_includes output, "def params(**kwargs)"
    assert_includes output, "def void"
  end

  def test_generate_opal_types_contains_struct
    output = SorbetTypesBat.generate_opal_types

    assert_includes output, "class Struct"
    assert_includes output, "def initialize(**kwargs)"
    assert_includes output, "def to_h"
  end

  def test_generate_writes_expected_content
    Dir.mktmpdir do |dir|
      SorbetTypesBat.generate(dir)

      browser_content = File.read("#{dir}/lib/sorbet-types/browser.rb")
      assert_includes browser_content, "module Browser"

      sorbet_content = File.read("#{dir}/lib/sorbet-types/sorbet.rb")
      assert_includes sorbet_content, "class Struct"
    end
  end
end
