#!/usr/bin/env ruby
# Check evidence completeness and artifact binding; this does not execute VM tests.
require "json"
require "digest"

module UnifiedAcceptance
  REQUIRED = %w[
    omarchy_public_cold_install omarchy_two_instances macos_install_desktop
    linux_iso_install workspace_window_lifecycle coordinated_quit
    focused_input_clipboard_isolation folder_permissions_and_removal
    guest_file_rollback workspace_portability cli_lifecycle
    windowed_fullscreen_display
  ].freeze

  DEFERRED_INPUT_ISSUE = "omarchy-keyboard-latency-return".freeze

  def self.verify(archive, report_path, version, commit)
    [archive, report_path].each do |path|
      raise "missing or unsafe acceptance input" unless File.file?(path) && !File.symlink?(path)
    end
    report = JSON.parse(File.read(report_path))
    raise "unsupported acceptance schema" unless report.is_a?(Hash) && [1, 2].include?(report["schemaVersion"])
    raise "candidate version mismatch" unless report["version"] == version
    raise "candidate source mismatch" unless commit.match?(/\A[0-9a-f]{40}\z/) && report["sourceCommit"] == commit
    raise "candidate archive mismatch" unless report["archiveSHA256"] == Digest::SHA256.file(archive).hexdigest
    %w[tester testedAt hostModel hostOS toolchain factoryManifestSHA256 agentRevision].each do |key|
      raise "missing acceptance metadata: #{key}" unless report[key].is_a?(String) && !report[key].strip.empty?
    end
    raise "invalid factory digest" unless report["factoryManifestSHA256"].match?(/\A[0-9a-f]{64}\z/)
    raise "invalid Agent revision" unless report["agentRevision"].match?(/\A[0-9a-f]{40}\z/)
    checks = report["checks"]
    raise "missing acceptance checks" unless checks.is_a?(Hash)
    base = File.realpath(File.dirname(report_path)) + File::SEPARATOR
    required = REQUIRED + (report["schemaVersion"] == 2 ? ["omarchy_keyboard_responsiveness"] : [])
    required.each do |name|
      check = checks[name]
      raise "missing acceptance check: #{name}" unless check.is_a?(Hash)
      if check["status"] == "deferred"
        unless report["schemaVersion"] == 2 && version == "0.1.0" &&
               name == "omarchy_keyboard_responsiveness" &&
               check["issue"] == DEFERRED_INPUT_ISSUE &&
               check["ownerApproval"] == "2026-09-07"
          raise "unapproved acceptance deferral: #{name}"
        end
      elsif check["status"] != "passed"
        raise "acceptance check not passed: #{name}"
      end
      raise "missing observed result: #{name}" unless check["observation"].is_a?(String) && !check["observation"].strip.empty?
      files = check["evidence"]
      raise "missing evidence: #{name}" unless files.is_a?(Array) && !files.empty?
      files.each do |file|
        raise "invalid evidence entry: #{name}" unless file.is_a?(Hash) && file["path"].is_a?(String)
        path = File.expand_path(file["path"], base)
        raise "evidence must be retained beside report: #{name}" unless File.file?(path) && !File.symlink?(path) && File.realpath(path).start_with?(base)
        raise "empty evidence: #{name}" if File.zero?(path)
        raise "evidence digest mismatch: #{name}" unless file["sha256"] == Digest::SHA256.file(path).hexdigest
      end
    end
    true
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: verify-unified-acceptance.rb <archive> <report.json> <version> <source-commit>" unless ARGV.length == 4
  begin
    UnifiedAcceptance.verify(*ARGV)
    puts "Verified artifact-bound unified acceptance record; review observations and any explicit input deferral."
  rescue StandardError => error
    warn "Unified acceptance rejected: #{error.message}"
    exit 1
  end
end
