# typed: false
# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/tooling/dev_server"

class DevServerTest < Minitest::Test
  def setup
    @server = Mochi::DevServer.new
    @tmp_root = Dir.mktmpdir("dev_server_test")
    @tmp_config = File.join(@tmp_root, "config.json")
  end

  def teardown
    FileUtils.rm_rf(@tmp_root)
  end

  def test_load_config_reads_routes
    File.write(@tmp_config, JSON.generate({ "routes" => { "/" => "index.html", "/about" => "about.html" } }))
    @server.load_config(@tmp_config)
    assert_equal "index.html", @server.route_mappings["/"]
    assert_equal "about.html", @server.route_mappings["/about"]
  end

  def test_load_config_missing_file
    out, _err = capture_io do
      @server.load_config("/nonexistent/path.json")
    end
    assert_match(/No config file found/, out)
  end

  def test_load_config_invalid_json
    File.write(@tmp_config, "not-json")
    out, _err = capture_io do
      @server.load_config(@tmp_config)
    end
    assert_match(/Could not parse config file/, out)
  end

  def test_get_content_type
    assert_equal "text/html", @server.get_content_type("foo.html")
    assert_equal "application/javascript", @server.get_content_type("foo.js")
    assert_equal "text/css", @server.get_content_type("foo.css")
    assert_equal "application/json", @server.get_content_type("foo.json")
    assert_equal "image/svg+xml", @server.get_content_type("foo.svg")
    assert_equal "application/octet-stream", @server.get_content_type("foo.unknown")
    assert_equal "image/jpeg", @server.get_content_type("foo.JPG")
  end

  def test_serve_file_exists
    File.write(File.join(@tmp_root, "test.txt"), "hello")
    context = Minitest::Mock.new
    context.expect(:[], nil, ["Content-Type"])
    context.expect(:[]=, nil, ["Content-Type", "text/plain"])
    context.expect(:response, OpenStruct.new(body: nil), [])
    assert @server.serve_file(context, @tmp_root, "test.txt")
  end

  def test_serve_file_missing
    context = Minitest::Mock.new
    refute @server.serve_file(context, @tmp_root, "missing.txt")
  end

  def test_reply_with_text
    context = Minitest::Mock.new
    context.expect(:[], nil, ["Content-Type"])
    context.expect(:[]=, nil, ["Content-Type", "text/plain"])
    context.expect(:response, OpenStruct.new(body: nil), [])
    @server.reply_with_text(context, "hello")
  end

  def test_rejects_invalid_config
    File.write(@tmp_config, "{")
    out, _err = capture_io do
      @server.load_config(@tmp_config)
    end
    assert_match(/Warning/, out)
  end
end
