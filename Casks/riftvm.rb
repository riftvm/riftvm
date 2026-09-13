# typed: strict
# frozen_string_literal: true

cask "riftvm" do
  # scripts/publish-release.sh rewrites these two lines from the notarized
  # archive before publishing, so keep them at the latest released version and
  # digest to keep the checked-in copy installable on its own.
  version "0.1.20"
  sha256 "71128cc3070bef1dc4ea2829e39083761507ca92a514cf7876e2ae692f14e52b"

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
