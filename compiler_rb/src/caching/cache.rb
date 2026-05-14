# typed: false
# frozen_string_literal: true

require "fileutils"
require_relative "warthogdb"

module Caching
  class Cache
    CACHE_DIR = File.expand_path("~/.cache/mochi")

    def initialize
      init_cache_dir
      @db = WarthogDB.new(CACHE_DIR)
    end

    def init_cache_dir
      FileUtils.mkdir_p(CACHE_DIR) unless Dir.exist?(CACHE_DIR)
    end

    def has(key)
      !!@db[key]
    rescue WarthogDB::NotFoundError
      false
    end

    def get(key)
      @db[key]
    end

    def put(key, value)
      @db[key] = value
    end

    def close
      @db.close
    end
  end
end
