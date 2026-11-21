#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

module DesktopDistribution
  DEVELOPER_ID = 'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'

  module_function

  def checked(*args)
    output, status = Open3.capture2e(*args)
    raise "#{args.first} failed:\n#{output.strip}" unless status.success?
    output
  end

  def zip(path, archive)
    checked("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", path, archive)
  end

  def verify_signature(app)
    checked("/usr/bin/codesign", "--verify", "--strict", "--deep", "-R=#{DEVELOPER_ID}", app)
  end

  def verify(archive)
    Dir.mktmpdir("mochi-verify-") do |work|
      checked("/usr/bin/ditto", "-x", "-k", archive, work)
      apps = Dir.glob(File.join(work, "*.app")).select { |path| File.directory?(path) && !File.symlink?(path) }
      raise "expected one app in #{archive}" unless apps.size == 1 && Dir.children(work) == [File.basename(apps.first)]
      app = apps.first
      verify_signature(app)
      checked("/usr/bin/xcrun", "stapler", "validate", app)
      puts checked("/usr/bin/syspolicy_check", "distribution", app)
    end
    puts "Verified #{archive}"
  end

  def package(source, output, identity, profile)
    raise "expected an app bundle at #{source}" unless source.end_with?(".app") && File.directory?(source)
    raise "output must be a .zip file" unless output.end_with?(".zip")
    raise "output already exists: #{output}" if File.exist?(output) || File.symlink?(output)
    raise "set MOCHI_SIGNING_IDENTITY to a Developer ID Application identity" if identity.to_s.strip.empty?
    raise "set MOCHI_NOTARY_PROFILE to a notarytool Keychain profile" if profile.to_s.strip.empty?

    Dir.mktmpdir(".mochi-distribution-", File.dirname(output)) do |work|
      app = File.join(work, File.basename(source))
      checked("/usr/bin/ditto", source, app)
      checked("/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp", app)
      verify_signature(app)
      submission = File.join(work, "submission.zip")
      zip(app, submission)
      result = JSON.parse(checked("/usr/bin/xcrun", "notarytool", "submit", submission,
        "--keychain-profile", profile, "--wait", "--timeout", "30m", "--output-format", "json"))
      unless result["status"] == "Accepted"
        raise "notarization #{result['status'] || 'did not finish'} (submission #{result['id'] || 'unknown'}). " \
          "Use xcrun notarytool log for the submission ID with the same Keychain profile."
      end
      puts "Notarization accepted for #{result.fetch('id')}"
      checked("/usr/bin/xcrun", "stapler", "staple", app)
      distribution = File.join(work, "distribution.zip")
      zip(app, distribution)
      verify(distribution)
      File.link(distribution, output)
    end
    puts "Packaged #{output}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise "macOS is required" unless RUBY_PLATFORM.include?("darwin")
    action, *arguments = ARGV
    case [action, arguments.length]
    when ["package", 2]
      source, output = arguments
      DesktopDistribution.package(File.expand_path(source), File.expand_path(output),
        ENV["MOCHI_SIGNING_IDENTITY"], ENV["MOCHI_NOTARY_PROFILE"])
    when ["verify", 1]
      DesktopDistribution.verify(File.expand_path(arguments.first))
    else
      abort "Usage: ruby runtime/desktop/distribute.rb package APP OUTPUT.zip | verify RELEASE.zip"
    end
  rescue RuntimeError, SystemCallError, JSON::ParserError, KeyError => error
    abort "mochi distribution: #{error.message}"
  end
end
