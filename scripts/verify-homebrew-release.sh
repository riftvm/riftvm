#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
vm_path="${2:-}"
expected_revision="${3:-${RIFTVM_EXPECTED_SOURCE_REVISION:-}}"
cask="${RIFTVM_HOMEBREW_CASK:-everettjf/tap/riftvm}"

fail() {
  echo "verify-homebrew-release: $*" >&2
  exit 1
}

[[ -n "$version" ]] || fail "usage: $0 <version> [smoke-vm] [source-revision]"
[[ -n "$expected_revision" ]] || \
  fail "expected source revision is required as argument 3 or RIFTVM_EXPECTED_SOURCE_REVISION"
[[ -n "$vm_path" || -n ${RIFTVM_RELEASE_PREINSTALLED_IMAGE:-} ]] ||
  fail "a standard smoke VM or preinstalled-image fixture is required"
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
if [[ -n $vm_path ]]; then
  "$project_root/scripts/verify-release-cli.sh" /Applications/RiftVM.app "$vm_path"
  "$project_root/scripts/verify-release-nested-virtualization.sh" /Applications/RiftVM.app "$vm_path"
  "$project_root/scripts/verify-release-vm.sh" /Applications/RiftVM.app "$vm_path"
fi

if [[ -n ${RIFTVM_RELEASE_PREINSTALLED_MANIFEST:-} || -n ${RIFTVM_RELEASE_PREINSTALLED_IMAGE:-} ]]; then
  [[ -n ${RIFTVM_RELEASE_PREINSTALLED_MANIFEST:-} && -n ${RIFTVM_RELEASE_PREINSTALLED_IMAGE:-} ]] ||
    fail "RIFTVM_RELEASE_PREINSTALLED_MANIFEST and RIFTVM_RELEASE_PREINSTALLED_IMAGE must be set together"
  "$project_root/scripts/verify-homebrew-preinstalled-image.sh" \
    "$RIFTVM_RELEASE_PREINSTALLED_MANIFEST" "$RIFTVM_RELEASE_PREINSTALLED_IMAGE"
fi

echo "Verified published Homebrew release RiftVM $version."
