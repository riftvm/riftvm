#!/usr/bin/env ruby
require "tmpdir"
require "json"
require "digest"
require "rbconfig"

verifier = File.expand_path("verify-notary-receipt.rb", __dir__)
Dir.mktmpdir("riftvm-notary-test") do |root|
  archive, response, digest = %w[archive.zip response.json archive.sha256].map { |name| File.join(root, name) }
  File.write(archive, "candidate one")
  File.write(digest, Digest::SHA256.file(archive).hexdigest)
  receipt = {"id" => "efa428ea-cda4-456f-aa11-0865d2af954f", "status" => "Accepted"}
  verify = lambda do |expected|
    actual = system(RbConfig.ruby, verifier, archive, response, digest, out: File::NULL, err: File::NULL)
    abort "unexpected verification result" unless actual == expected
  end
  File.write(response, JSON.generate(receipt))
  verify.call(true)
  %w[Invalid Rejected InProgress].each do |status|
    File.write(response, JSON.generate(receipt.merge("status" => status)))
    verify.call(false)
  end
  File.write(response, JSON.generate(receipt.merge("id" => "")))
  verify.call(false)
  File.write(response, "") # Legacy marker must not suffice.
  verify.call(false)
  File.write(response, JSON.generate(receipt))
  File.write(archive, "candidate two")
  verify.call(false)
  File.write(digest, Digest::SHA256.file(archive).hexdigest)
  verify.call(true)
  File.unlink(response)
  verify.call(false)
end
puts "Notarization receipt regression checks passed."
