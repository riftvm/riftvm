# typed: strict
# frozen_string_literal: true

cask "riftvm" do
  version "1.0.4"
  sha256 "77bff3203756aab11aa512715a53839036360f40c420f328d7b435857a749925"

  url "https://github.com/riftvm/riftvm/releases/download/v#{version}/RiftVM-#{version}.zip?notarized=1"
  name "RiftVM"
  desc "Simple native virtual machines for Apple silicon Macs"
  homepage "https://xnu.app/riftvm"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "RiftVM.app"
  binary "#{appdir}/RiftVM.app/Contents/Helpers/riftvm"

  zap trash: [
    "~/Library/Application Support/RiftVM",
    "~/Library/Preferences/com.riftvm.app.plist",
    "~/Library/Saved Application State/com.riftvm.app.savedState",
  ]
end
