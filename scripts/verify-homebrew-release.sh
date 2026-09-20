#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
expected_revision="${2:-${RIFTVM_EXPECTED_SOURCE_REVISION:-}}"
cask="${RIFTVM_HOMEBREW_CASK:-riftvm/tap/riftvm}"

fail() {
  echo "verify-homebrew-release: $*" >&2
  exit 1
}

[[ -n "$version" ]] || fail "usage: $0 <version> [source-revision]"
[[ -n "$expected_revision" ]] || \
  fail "expected source revision is required as argument 3 or RIFTVM_EXPECTED_SOURCE_REVISION"
command -v brew >/dev/null 2>&1 || fail "Homebrew is required"
[[ ! -d /Applications/RiftVM.app ]] || ! pgrep -x RiftVM >/dev/null || \
  fail "quit RiftVM before verifying the Homebrew release"

brew update
if brew list --cask --versions riftvm >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask "$cask"
  installed_version="$(brew list --cask --versions riftvm | awk '{print $2}')"
  if [[ $installed_version != "$version" ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew reinstall --cask "$cask"
  fi
else
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "$cask"
fi

installed_version="$(brew list --cask --versions riftvm | awk '{print $2}')"
[[ "$installed_version" == "$version" ]] || \
  fail "Homebrew installed $installed_version, expected $version"

"$project_root/scripts/verify-release-app.sh" \
  /Applications/RiftVM.app "$version" "$expected_revision"
# The installed app must trust the factory channel it pins, or preparing
# Omarchy fails for everyone on that release.
"$project_root/scripts/verify-factory-trust.sh" /Applications/RiftVM.app

echo "Verified published Homebrew release RiftVM $version."
