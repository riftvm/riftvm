# typed: strict
# frozen_string_literal: true

cask "riftvm" do
  # scripts/publish-release.sh rewrites these two lines from the notarized
  # archive before publishing, so keep them at the latest released version and
  # digest to keep the checked-in copy installable on its own.
  version "0.4.0"
  sha256 "583e659b049ac5e7322b41eed1d739ad19f117b3a3bcf49b16c2f9bb07a64e1d"

  url "https://github.com/riftvm/riftvm/releases/download/riftvm-v#{version}/RiftVM-#{version}.zip?notarized=1"
  name "RiftVM"
  desc "Simple native virtual machines for Apple silicon Macs"
  homepage "https://riftvm.com"

  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "RiftVM.app"

  zap trash: [
    "~/Library/Application Support/RiftVM",
    "~/Library/Preferences/com.riftvm.app.plist",
    "~/Library/Saved Application State/com.riftvm.app.savedState",
  ]
end
