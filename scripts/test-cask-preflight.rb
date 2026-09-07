#!/usr/bin/env ruby
# Run with brew ruby scripts/test-cask-preflight.rb; never installs artifacts.
require "cask/cask_loader"
require "tmpdir"
require "digest"

source = File.read(File.join(__dir__, "templates/riftvm.rb.in"))
source = source.sub("@VERSION@", "0.1.0").sub("@SHA256@", "0" * 64)
cask = Cask::CaskLoader::FromContentLoader.new(source).load(config: nil)
flight = cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::PreflightBlock) }
abort "missing OS preflight" unless flight
original = MacOS.method(:version)
begin
  [26, 27, 28].each do |major|
    MacOS.define_singleton_method(:version) { Version.new(major.to_s) }
    accepted = true
    begin
      flight.install_phase
    rescue RuntimeError => error
      raise unless error.message == "RiftVM requires macOS 27 or later."
      accepted = false
    end
    abort "incorrect macOS #{major} gate" unless accepted == (major >= 27)
  end
ensure
  MacOS.define_singleton_method(:version, original)
end
puts "Actual Cask preflight rejected macOS 26 and accepted macOS 27 and 28."
