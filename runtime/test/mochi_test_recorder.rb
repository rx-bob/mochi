require "json"

module Mochi
  module Test
    class Scenario
      attr_reader :steps

      def initialize
        @steps = []
      end

      def mount(tag_name, props = {})
        record("mount", { "tag" => tag_name.to_s, "props" => props })
      end

      def click(selector)
        record("click", { "selector" => selector.to_s })
      end

      def fill(selector, value)
        record("fill", { "selector" => selector.to_s, "value" => value.to_s })
      end

      def wait_for_settled
        record("wait")
      end

      def assert_text(selector, expected)
        record("assert_text", {
          "selector" => selector.to_s,
          "expected" => expected.to_s
        })
      end

      private

      def record(operation, attributes = {})
        location = caller_locations(2, 1).first
        @steps << attributes.merge(
          "operation" => operation,
          "source" => location ? location.path : "<ruby test>",
          "line" => location ? location.lineno : 1
        )
      end
    end

    @cases = []

    def self.test(name, &block)
      raise ArgumentError, "test requires a block" unless block

      scenario = Scenario.new
      scenario.instance_exec(&block)
      @cases << { "name" => name.to_s, "steps" => scenario.steps }
    end

    def self.write_plan(path)
      raise "no Ruby tests found" if @cases.empty?

      File.write(path, JSON.pretty_generate({ "tests" => @cases }))
    end
  end
end

test_dir = ARGV.fetch(0)
plan_path = ARGV.fetch(1)
files = Dir.glob(File.join(test_dir, "**", "*_test.rb")).sort
abort("no *_test.rb files found under #{test_dir}") if files.empty?
files.each { |file| load(file) }
Mochi::Test.write_plan(plan_path)
