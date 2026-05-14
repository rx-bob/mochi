# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "fileutils"
require "securerandom"

class BuilderMan
  extend T::Sig

  sig { returns(String) }
  attr_reader :input_dir

  sig { returns(String) }
  attr_reader :build_id

  sig { params(input_dir: String).void }
  def initialize(input_dir)
    @input_dir = input_dir
    @build_id = generate_build_id

    create_mochi_dir_if_missing

    opal_rt_file = "runtime.js"
    entries_to_delete = Dir.entries(build_dir).reject do |entry|
      entry == "." || entry == ".." || entry == opal_rt_file
    end

    paths_to_delete = entries_to_delete.map { |entry| File.join(build_dir, entry) }

    build_dir_path = build_dir
    if Dir.exist?(build_dir_path)
      unless paths_to_delete.empty?
        FileUtils.rm_rf(paths_to_delete)
      else
        puts "Nothing to delete."
      end
      FileUtils.mkdir_p(build_dir_path)
    else
      FileUtils.mkdir_p(build_dir_path)
    end
  end

  sig { void }
  def create_mochi_dir_if_missing
    bd = build_dir
    if Dir.exist?(bd)
      # exists, do nothing
    else
      FileUtils.mkdir_p(bd)
    end
  end

  sig { returns(String) }
  def build_dir
    "#{Dir.pwd}/build"
  end

  sig { returns(String) }
  def ruby_src_dir
    "#{build_dir}/src"
  end

  sig { returns(String) }
  def pre_tp_dir
    "#{build_dir}/pre_tp"
  end

  sig { void }
  def copy_ruby_code_to_pre_tp
    source_dir = "#{@input_dir}/*"
    destination_dir = pre_tp_dir
    FileUtils.mkdir_p(destination_dir)
    files = Dir.glob(source_dir)
    FileUtils.cp_r(files, destination_dir) unless files.empty?
  end

  sig { void }
  def copy_ruby_code_base
    source_dir = "#{pre_tp_dir}/*"
    destination_dir = ruby_src_dir
    FileUtils.mkdir_p(destination_dir)
    files = Dir.glob(source_dir)
    FileUtils.cp_r(files, destination_dir) unless files.empty?
  end

  private

  sig { returns(String) }
  def generate_build_id
    random_part = SecureRandom.hex(16)
    time_part = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    "#{random_part}#{time_part}"
  end
end
