# typed: strict
# frozen_string_literal: true

cask "riftvm" do
  # scripts/publish-release.sh rewrites these two lines from the notarized
  # archive before publishing, so keep them at the latest released version and
  # digest to keep the checked-in copy installable on its own.
  version "0.1.17"
  sha256 "47bd68d998751194f4679a43496a5552d130da69ce9615f8cb99ee5e899bd314"

  url "https://github.com/riftvm/riftvm/releases/download/riftvm-v#{version}/RiftVM-#{version}.zip?notarized=1"
  name "RiftVM"
  desc "Simple native virtual machines for Apple silicon Macs"
  homepage "https://riftvm.com"

  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "RiftVM.app"
  binary "#{appdir}/RiftVM.app/Contents/Helpers/riftvm"

  zap trash: [
    "~/Library/Application Support/RiftVM",
    "~/Library/Preferences/com.riftvm.app.plist",
    "~/Library/Saved Application State/com.riftvm.app.savedState",
  ]
end
