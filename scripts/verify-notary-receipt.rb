#!/usr/bin/env ruby
# Validate a local notarytool submit receipt against the submitted archive.
require "json"
require "digest"

begin
  abort "usage: verify-notary-receipt.rb <archive> <response.json> <digest>" unless ARGV.length == 3
  archive, response, digest_path = ARGV
  [archive, response, digest_path].each do |path|
    abort "missing or unsafe notarization input" unless File.file?(path) && !File.symlink?(path)
  end
  receipt = JSON.parse(File.read(response))
  abort "Apple did not accept this submission" unless receipt["status"] == "Accepted"
  abort "missing submission identifier" unless receipt["id"].is_a?(String) &&
    receipt["id"].match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i)
  digest = File.read(digest_path).strip
  abort "notarization archive mismatch" unless digest.match?(/\A[0-9a-f]{64}\z/) &&
    digest == Digest::SHA256.file(archive).hexdigest
  puts "Verified accepted notarization receipt for the exact archive."
rescue JSON::ParserError, SystemCallError, TypeError => error
  warn "Invalid notarization receipt: #{error.message}"
  exit 1
end
