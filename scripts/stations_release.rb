#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "toolchain_archive"
require_relative "../runtime/desktop/distribute"

module StationsRelease
  ROOT = File.expand_path("..", __dir__)
  PROJECT = File.join(ROOT, "e2e/fixtures/clay_inspector")
  OFFLINE = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)"].freeze

  module_function

  def run(*args, **options)
    raise "#{args.grep(String).first} failed" unless system(*args, **options)
  end

  def install(archives, work, environment)
    cpu = ToolchainArchive.architecture
    installer = File.join(work, "Installer")
    ToolchainArchive.unpack(File.join(archives, "mochi-macos-#{cpu}.tar.gz"), installer)
    addon = File.join(archives, "mochi-desktop-macos-#{cpu}.tar.gz")
    prefix = File.join(work, "Mochi Prefix")
    run(environment, "/usr/bin/ruby", File.join(installer, "install.rb"), "--prefix", prefix,
      "--desktop", addon, chdir: work, unsetenv_others: true)
    prefix
  end

  def verify(web_zip, mac_zip, prefix, work, environment)
    extracted = File.join(work, "Recipient downloads")
    web = File.join(extracted, "web")
    mac = File.join(extracted, "mac")
    FileUtils.mkdir_p([web, mac])
    DesktopDistribution.checked("/usr/bin/ditto", "-x", "-k", web_zip, web)
    DesktopDistribution.checked("/usr/bin/ditto", "-x", "-k", mac_zip, mac)
    site = File.join(web, "stations")
    app = File.join(mac, "Stations.app")
    host = File.join(app, "Contents/MacOS/Mochi")
    record = JSON.parse(File.read(File.join(prefix, "share/mochi/install.json")))
    desktop = record.fetch("desktop_identity")
    architecture = desktop.fetch("architecture")
    identity = ToolchainArchive.desktop_identity(architecture, desktop.fetch("capacity_fingerprint"))
    ToolchainArchive.verify_native(host, identity)

    plan = File.join(work, "editor-test.json")
    run("ruby", File.join(ROOT, "runtime/test/mochi_test_recorder.rb"),
      File.join(PROJECT, "test"), plan, "editor_test.rb")
    run("node", File.join(ROOT, "e2e/mochi_test_runner.cjs"),
      site, plan, "chromium,firefox,webkit", "/deployments/tenant/stations")

    resources = File.join(app, "Contents/Resources")
    native_environment = environment.merge("MOCHI_DESKTOP_STORAGE_DIR" => File.join(work, "App storage"))
    run(native_environment, *OFFLINE, desktop.fetch("replay"), resources, plan, chdir: mac, unsetenv_others: true)
    run(native_environment, *OFFLINE, host, "--mochi-verify-app", chdir: mac, unsetenv_others: true)
    puts DesktopDistribution.checked("/usr/bin/sw_vers", "-productVersion").strip.prepend("Tested macOS ")
    puts DesktopDistribution.checked("/usr/bin/xcrun", "vtool", "-show-build", host)
    puts "Verified #{architecture} AppKit replay and offline app launch"
    puts "SHA-256 #{ToolchainArchive.checksum(web_zip)}  #{File.basename(web_zip)}"
    puts "SHA-256 #{ToolchainArchive.checksum(mac_zip)}  #{File.basename(mac_zip)}"
  end

  def build(output, prefix, work, environment)
    project = File.join(work, "Stations Project")
    FileUtils.cp_r(PROJECT, project)
    cli = File.join(prefix, "bin/mochi")
    web = File.join(work, "Web output", "stations")
    mac = File.join(work, "Mac output")
    run(environment, cli, "-i", project, "-o", web, chdir: work, unsetenv_others: true)
    run(environment, cli, "--target=desktop", "-i", project, "-o", mac, chdir: work, unsetenv_others: true)

    staging = File.join(work, "Candidate")
    FileUtils.mkdir(staging)
    web_zip = File.join(staging, "stations-web.zip")
    mac_zip = File.join(staging, "stations-macos-#{ToolchainArchive.architecture}-local.zip")
    DesktopDistribution.zip(web, web_zip)
    DesktopDistribution.zip(File.join(mac, "Stations.app"), mac_zip)
    verify(web_zip, mac_zip, prefix, work, environment)

    FileUtils.mkdir_p(output)
    result = Dir.mktmpdir("run.", output)
    FileUtils.cp([web_zip, mac_zip], result)
    puts "Verified candidate archives in #{result}"
  end
end

begin
  action, archives, *arguments = ARGV
  unless (action == "build" && arguments.size == 1) || (action == "verify" && arguments.size == 2)
    abort "Usage: ruby scripts/stations_release.rb build TOOLCHAINS OUTPUT_DIR | verify TOOLCHAINS WEB.zip MAC.zip"
  end
  Dir.mktmpdir("mochi stations release ") do |work|
    environment = {"PATH" => "/usr/bin:/bin", "HOME" => work}
    prefix = StationsRelease.install(File.expand_path(archives), work, environment)
    paths = arguments.map { |path| File.expand_path(path) }
    if action == "build"
      StationsRelease.build(paths.first, prefix, work, environment)
    else
      DesktopDistribution.verify(paths.last)
      StationsRelease.verify(*paths, prefix, work, environment)
    end
  end
rescue RuntimeError, SystemCallError, KeyError => error
  abort "stations release: #{error.message}"
end
