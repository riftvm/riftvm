# typed: strict
# frozen_string_literal: true

cask "riftvm" do
  # scripts/publish-release.sh rewrites these two lines from the notarized
  # archive before publishing, so keep them at the latest released version and
  # digest to keep the checked-in copy installable on its own.
  version "0.5.1"
  sha256 "8b872e25209f7d7739d22cb50c8791d8e3d0049b0d419d35aa441b66a13a75cc"

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
