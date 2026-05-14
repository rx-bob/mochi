# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/tree_sitter/instance_var_analyzer"

describe TreeSitter::InstanceVarAnalyzer do
  it "categorizes manual assigned variables correctly" do
    source = <<-RUBY
    class Counter
      def initialize
        @count = 0
        @name = "Test"
      end

      def inc
        @count += 1
      end

      def html
        "<div>{@count}</div>"
      end

      def print_name
        puts @name
      end
    end
    RUBY

    vars = TreeSitter::InstanceVarAnalyzer.analyze(source)
    count_var = vars.find { |v| v.name == "@count" }
    name_var = vars.find { |v| v.name == "@name" }

    refute_nil count_var
    refute_nil name_var

    _(count_var.category).must_equal TreeSitter::InstanceVarAnalyzer::Category::State
    _(count_var.is_bound).must_equal true
    _(count_var.writes).must_equal 2

    _(name_var.category).must_equal TreeSitter::InstanceVarAnalyzer::Category::Constant
    _(name_var.is_bound).must_equal false
    _(name_var.writes).must_equal 1
    _(name_var.reads).must_equal 1
  end

  it "handles attr_accessor and attr_reader" do
    source = <<-RUBY
    class UserInfo
      attr_accessor :user_id
      attr_reader :session

      def html
        "<span>{@user_id} - {@session}</span>"
      end
    end
    RUBY

    vars = TreeSitter::InstanceVarAnalyzer.analyze(source)
    user_id = vars.find { |v| v.name == "@user_id" }
    session = vars.find { |v| v.name == "@session" }

    refute_nil user_id
    refute_nil session

    _(user_id.category).must_equal TreeSitter::InstanceVarAnalyzer::Category::State
    _(user_id.is_bound).must_equal true
    # because user_id has attr_accessor
    _(user_id.attr_mutated).must_equal true

    _(session.category).must_equal TreeSitter::InstanceVarAnalyzer::Category::Derived
    # Because "session" only has attr_reader and reads in string:
    # 0 manual writes inside or outside the constructor
    _(session.attr_mutated).must_equal false
    _(session.is_bound).must_equal true
  end

  it "handles purely derived variables with standard ruby interpolation" do
    source = <<-'RUBY'
    class Profile
      def get_full_name
        "#{@first} #{@last}"
      end

      def html
        "<div>\#{get_full_name}</div>"
      end
    end
    RUBY

    vars = TreeSitter::InstanceVarAnalyzer.analyze(source)
    first_var = vars.find { |v| v.name == "@first" }
    last_var = vars.find { |v| v.name == "@last" }

    refute_nil first_var
    refute_nil last_var

    _(first_var.category).must_equal TreeSitter::InstanceVarAnalyzer::Category::Derived
    _(last_var.category).must_equal TreeSitter::InstanceVarAnalyzer::Category::Derived

    _(first_var.reads).must_equal 1
    _(first_var.is_bound).must_equal false # used in get_full_name, not html directly
  end
end
