# typed: false
# frozen_string_literal: true

require "webrick"
require "json"
require "pathname"

module Mochi
  class DevServer
    def initialize
      @route_mappings = {} # type: Hash[String, String]
    end

    attr_reader :route_mappings

    def load_config(config_path)
      if File.exist?(config_path)
        puts "Loading config from '#{config_path}'"
        begin
          config_content = File.read(config_path)
          json = JSON.parse(config_content)

          if routes = json["routes"]
            routes.each do |path, file|
              @route_mappings[path.to_s] = file.to_s
            end
          end

          puts "Loaded #{@route_mappings.size} route mapping(s) from config:"
          @route_mappings.each do |path, file|
            puts "  #{path} -> #{file}"
          end
        rescue JSON::ParserError, StandardError => e
          puts "Warning: Could not parse config file: #{e.message}"
        end
      else
        puts "No config file found at #{config_path}, using defaults"
      end
    end

    def get(wanted_uri, context)
      context.request_method == "GET" && context.request_uri.to_s == wanted_uri
    end

    def reply_with_file(context, path, content_type)
      content = File.read(path)
      context["Content-Type"] = content_type
      context.response.body = content
    end

    def reply_with_text(context, content)
      context["Content-Type"] = "text/plain"
      context.response.body = content
    end

    def get_content_type(file_path)
      extension = File.extname(file_path).downcase
      case extension
      when ".html"
        "text/html"
      when ".js"
        "application/javascript"
      when ".css"
        "text/css"
      when ".json"
        "application/json"
      when ".png"
        "image/png"
      when ".jpg", ".jpeg"
        "image/jpeg"
      when ".gif"
        "image/gif"
      when ".webp"
        "image/webp"
      when ".avif"
        "image/avif"
      when ".svg"
        "image/svg+xml"
      when ".ico"
        "image/x-icon"
      when ".mp4", ".mp4v", ".mpg4"
        "video/mp4"
      when ".webm"
        "video/webm"
      when ".woff"
        "font/woff"
      when ".woff2"
        "font/woff2"
      when ".ttf"
        "font/ttf"
      when ".xml"
        "application/xml"
      when ".txt"
        "text/plain"
      else
        "application/octet-stream"
      end
    end

    def serve_file(context, root_dir, uri_path)
      file_path = File.join(root_dir, uri_path)

      if File.exist?(file_path) && File.file?(file_path)
        content_type = get_content_type(file_path)
        reply_with_file(context, file_path, content_type)
        return true
      end

      false
    end

    def start(root_dir = "", config_path = "")
      load_config(config_path) unless config_path.empty?

      root_dir = Dir.pwd if root_dir.empty?

      start_server(root_dir)
    end

    private

    def start_server(root_dir)
      @route_mappings.keys.each { |k| puts "route_mapping: #{k} -> #{@route_mappings[k]}" }

      server = WEBrick::HTTPServer.new(Port: 27490, DocumentRoot: root_dir)

      server.mount_proc '/' do |req, res|
        method = req.request_method
        uri = req.path

        puts "#{method} '#{uri}'"

        res["Server"] = "mochi-dev-server"

        replied = false

        # Check custom route mappings from config
        if method == "GET" && @route_mappings.has_key?(uri)
          file_name = @route_mappings[uri]
          file_path = File.join(root_dir, file_name)

          if File.exist?(file_path)
            res.content_type = get_content_type(file_path)
            res.body = File.read(file_path)
            replied = true
          end
        end

        # Handle root special
        if !replied && uri == "/"
          index_html_file = "#{root_dir}/index.html"
          if File.exist?(index_html_file)
            res.content_type = get_content_type(index_html_file)
            res.body = File.read(index_html_file)
          else
            res.content_type = "text/plain"
            res.body = "Mochi Dev Server is running."
          end
          replied = true
        end

        # Dynamically serve any file based on URI path
        if !replied && method == "GET"
          file_path = File.join(root_dir, uri)
          if File.exist?(file_path) && File.file?(file_path)
            res.content_type = get_content_type(file_path)
            res.body = File.read(file_path)
            replied = true
          end
        end

        if !replied
          res.status = 404
          res.content_type = "text/plain"
          res.body = "Error: No handler for #{method} #{uri}"
        end
      end

      puts "Mochi Dev Server listening on http://127.0.0.1:27490 with root dir '#{root_dir}'"
      trap("INT") { server.shutdown }
      server.start
    end
  end
end
