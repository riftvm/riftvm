#!/usr/bin/env ruby
require "minitest/autorun"
require "tmpdir"
require_relative "verify-unified-acceptance"

class UnifiedAcceptanceTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("riftvm-acceptance-")
    @archive = File.join(@dir, "candidate.zip")
    @report_path = File.join(@dir, "acceptance.json")
    File.write(@archive, "candidate bytes")
    File.write(File.join(@dir, "observations.txt"), "Observed guest behavior with this candidate")
    @report = {
      "schemaVersion" => 1, "version" => "0.1.0", "sourceCommit" => "a" * 40,
      "archiveSHA256" => Digest::SHA256.file(@archive).hexdigest,
      "tester" => "Test fixture", "testedAt" => "2026-09-07T12:00:00Z",
      "hostModel" => "Test Mac", "hostOS" => "27 build test", "toolchain" => "27 build test",
      "factoryManifestSHA256" => "b" * 64, "agentRevision" => "c" * 40,
      "checks" => UnifiedAcceptance::REQUIRED.to_h { |name| [name, {
        "status" => "passed", "observation" => "Synthetic verifier test only",
        "evidence" => [{"path" => "observations.txt", "sha256" => Digest::SHA256.file(File.join(@dir, "observations.txt")).hexdigest}]
      }] }
    }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def verify
    File.write(@report_path, JSON.generate(@report))
    UnifiedAcceptance.verify(@archive, @report_path, "0.1.0", "a" * 40)
  end

  def test_complete_bound_record
    assert verify
  end

  def test_rejects_different_candidate_bytes
    File.write(@archive, "rebuilt candidate")
    assert_raises(RuntimeError) { verify }
  end

  def test_rejects_wrong_source_and_version
    @report["sourceCommit"] = "d" * 40
    assert_raises(RuntimeError) { verify }
    @report["sourceCommit"] = "a" * 40
    @report["version"] = "0.2.0"
    assert_raises(RuntimeError) { verify }
  end

  def test_each_required_check_must_pass
    UnifiedAcceptance::REQUIRED.each do |name|
      check = @report["checks"].delete(name)
      assert_raises(RuntimeError, name) { verify }
      @report["checks"][name] = check.merge("status" => "pending")
      assert_raises(RuntimeError, name) { verify }
      @report["checks"][name] = check
    end
  end

  def test_rejects_missing_or_changed_evidence
    File.write(File.join(@dir, "observations.txt"), "changed")
    assert_raises(RuntimeError) { verify }
    File.delete(File.join(@dir, "observations.txt"))
    assert_raises(RuntimeError) { verify }
  end

  def test_rejects_empty_observation
    @report["checks"].values.first["observation"] = " "
    assert_raises(RuntimeError) { verify }
  end

  def test_rejects_symlink_evidence
    File.rename(File.join(@dir, "observations.txt"), File.join(@dir, "original.txt"))
    File.symlink("original.txt", File.join(@dir, "observations.txt"))
    assert_raises(RuntimeError) { verify }
  end

  def test_rejects_missing_factory_provenance
    @report.delete("factoryManifestSHA256")
    assert_raises(RuntimeError) { verify }
  end
  def enable_input_deferral
    @report["schemaVersion"] = 2
    @report["checks"]["omarchy_keyboard_responsiveness"] =
      @report["checks"].values.first.merge(
        "status" => "deferred", "issue" => UnifiedAcceptance::DEFERRED_INPUT_ISSUE,
        "ownerApproval" => "2026-09-07")
  end

  def test_explicit_input_deferral_retains_evidence_requirements
    enable_input_deferral
    assert verify
    @report["checks"]["omarchy_keyboard_responsiveness"]["evidence"] = []
    assert_raises(RuntimeError) { verify }
  end

  def test_deferral_cannot_waive_other_checks
    enable_input_deferral
    UnifiedAcceptance::REQUIRED.each do |name|
      check = @report["checks"][name]
      @report["checks"][name] = @report["checks"]["omarchy_keyboard_responsiveness"]
      assert_raises(RuntimeError, name) { verify }
      @report["checks"][name] = check
    end
  end

  def test_deferral_requires_exact_issue_and_approval
    enable_input_deferral
    check = @report["checks"]["omarchy_keyboard_responsiveness"]
    %w[issue ownerApproval].each do |key|
      value = check.delete(key)
      assert_raises(RuntimeError) { verify }
      check[key] = value
    end
    @report["schemaVersion"] = 1
    @report["checks"]["focused_input_clipboard_isolation"] = check
    assert_raises(RuntimeError) { verify }
  end

  def test_schema_two_requires_keyboard_result
    @report["schemaVersion"] = 2
    assert_raises(RuntimeError) { verify }
  end

end
