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

      def download(selector)
        record("download", { "selector" => test_selector(selector) })
      end

      def assert_download(filename:, bytes:)
        unless filename.is_a?(String) && !filename.empty?
          raise ArgumentError, "download filename must be a non-empty String"
        end
        unless bytes.is_a?(String) || (bytes.is_a?(Array) && bytes.all? { |byte| byte.is_a?(Integer) && byte.between?(0, 255) })
          raise ArgumentError, "download bytes must be a String or an Array of bytes"
        end
        content = bytes.is_a?(String) ? bytes.bytes : bytes
        raise ArgumentError, "download bytes exceed the 16 MiB harness limit" if content.length > 16 * 1024 * 1024
        record("assert_download", { "filename" => filename, "bytes" => content })
      end

      def fill(selector, value)
        record("fill", { "selector" => selector.to_s, "value" => value.to_s })
      end

      def focus(selector)
        record("focus", { "selector" => test_selector(selector) })
      end

      def press(key)
        raise ArgumentError, "press requires a non-empty key" unless key.is_a?(String) && !key.strip.empty?
        record("press", { "key" => key })
      end

      def assert_focused(selector)
        record("assert_focused", { "selector" => test_selector(selector) })
      end

      def select_files(selector, files:)
        record("select_files", { "selector" => test_selector(selector), "files" => test_files(files) })
      end

      def drop_files(selector, files:)
        record("drop_files", { "selector" => test_selector(selector), "files" => test_files(files) })
      end

      def drag(source, target)
        record("drag", { "source" => test_selector(source), "target" => test_selector(target) })
      end

      def pointer_press(selector)
        record("pointer_press", { "selector" => selector.to_s })
      end

      def pointer_move_by(x, y, steps: 1)
        record("pointer_move_by", { "x" => Integer(x), "y" => Integer(y), "steps" => Integer(steps) })
      end

      def pointer_release
        record("pointer_release")
      end

      def pointer_cancel
        record("pointer_cancel")
      end

      def pointer_lose_capture
        record("pointer_lose_capture")
      end

      def assert_pointer_capture_released
        record("assert_pointer_capture_released")
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

      def assert_state(selector, expected)
        record("assert_state", {
          "selector" => test_selector(selector),
          "expected" => expected.to_s
        })
      end

      def assert_attribute(selector, name, expected)
        record("assert_attribute", { "selector" => selector.to_s, "name" => name.to_s, "expected" => expected.to_s })
      end

      def assert_no_attribute(selector, name)
        record("assert_no_attribute", { "selector" => selector.to_s, "name" => name.to_s })
      end

      def assert_value(selector, expected)
        record("assert_value", { "selector" => selector.to_s, "expected" => expected.to_s })
      end

      def expect_error(message)
        unless message.is_a?(String) && !message.strip.empty?
          raise ArgumentError, "expect_error requires a non-empty message"
        end
        record("expect_error", { "message" => message })
      end

      def unmount
        record("unmount")
      end

      def remount(tag_name = nil, props = {})
        record("remount", { "tag" => tag_name&.to_s, "props" => props })
      end

      private

      def test_selector(selector)
        value = selector.to_s
        raise ArgumentError, "test selector must not be empty" if value.empty?
        value
      end

      def test_files(files)
        raise ArgumentError, "files must be a non-empty Array" unless files.is_a?(Array) && !files.empty?

        files.map do |file|
          raise ArgumentError, "each test file must be a Hash" unless file.is_a?(Hash)
          attributes = file.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
          allowed = %w[path name type bytes last_modified delay_ms fail_read]
          unknown = attributes.keys - allowed
          raise ArgumentError, "unsupported test file fields: #{unknown.join(", ")}" unless unknown.empty?
          has_path = attributes["path"].is_a?(String) && !attributes["path"].empty?
          has_bytes = attributes.key?("bytes")
          raise ArgumentError, "test file needs exactly one of path or bytes" if has_path == has_bytes
          raise ArgumentError, "test file path must be a non-empty String" if attributes.key?("path") && !has_path
          if has_bytes
            bytes = attributes["bytes"]
            unless bytes.is_a?(String) ||
                   (bytes.is_a?(Array) && bytes.all? { |byte| byte.is_a?(Integer) && byte.between?(0, 255) })
              raise ArgumentError, "test file bytes must be a String or an Array of bytes"
            end
            byte_count = bytes.is_a?(String) ? bytes.bytesize : bytes.length
            raise ArgumentError, "test file bytes exceed the 16 MiB harness limit" if byte_count > 16 * 1024 * 1024
          end
          if attributes.key?("delay_ms") &&
             (!attributes["delay_ms"].is_a?(Integer) || !attributes["delay_ms"].between?(0, 1_000))
            raise ArgumentError, "test file delay_ms must be between 0 and 1000"
          end
          if attributes.key?("fail_read") && ![true, false].include?(attributes["fail_read"])
            raise ArgumentError, "test file fail_read must be true or false"
          end
          attributes
        end
      end

      def record(operation, attributes = {})
        location = caller_locations(2, 1).first
        @steps << attributes.merge(
          "operation" => operation,
          "ruby_file" => location ? location.path : "<ruby test>",
          "line" => location ? location.lineno : 1
        )
      end
    end

    @cases = []

    def self.test(name, &block)
      raise ArgumentError, "test requires a block" unless block

      location = caller_locations(1, 1).first
      scenario = Scenario.new
      scenario.instance_exec(&block)
      @cases << { "name" => name.to_s, "steps" => scenario.steps,
                  "ruby_file" => location.path, "line" => location.lineno }
    end

    def self.write_plan(path)
      raise "no Ruby tests found" if @cases.empty?

      File.write(path, JSON.pretty_generate({ "tests" => @cases }))
    end
  end
end

test_dir = File.expand_path(ARGV.fetch(0))
plan_path = ARGV.fetch(1)
files = Dir.glob(File.join(test_dir, "**", "*_test.rb")).sort
selection = ARGV[2]
if selection
  selected = File.expand_path(selection, test_dir)
  unless files.include?(selected)
    abort("no Ruby test file '#{selection}' under #{test_dir}; select a relative *_test.rb path")
  end
  files = [selected]
end
abort("no *_test.rb files found under #{test_dir}") if files.empty?
files.each { |file| load(file) }
Mochi::Test.write_plan(plan_path)
