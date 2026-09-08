#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
shipping_paths=(CLI Casks GuestAgent RiftVM Tests Tools Experiments scripts .github Package.swift README.md THIRD_PARTY_NOTICES.md)
old_pattern='EZVM|EasyVM|ezvm|easyvm'
old_bundle_pattern='com\.everettjf\.riftvm'

cd "$project_root"

content_matches="$(rg -n --hidden -g '!.git/**' -g '!.build/**' -g '!verify-riftvm-identity.sh' \
  "$old_pattern" "${shipping_paths[@]}" || true)"
if [[ -n "$content_matches" ]]; then
  echo "Legacy product identity remains in shipping content:" >&2
  echo "$content_matches" >&2
  exit 1
fi

legacy_bundle_matches="$(rg -n --hidden -g '!.git/**' -g '!.build/**' -g '!verify-riftvm-identity.sh' \
  "$old_bundle_pattern" "${shipping_paths[@]}" || true)"
if [[ -n "$legacy_bundle_matches" ]]; then
  echo "Legacy RiftVM bundle identity remains in shipping content:" >&2
  echo "$legacy_bundle_matches" >&2
  exit 1
fi

grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.riftvm.app;' RiftVM/RiftVM.xcodeproj/project.pbxproj || {
  echo "RiftVM app target does not use com.riftvm.app." >&2
  exit 1
}

path_matches="$(find "${shipping_paths[@]}" -path '*/.build' -prune -o \
  \( -name '*EZVM*' -o -name '*EasyVM*' -o -name '*ezvm*' -o -name '*easyvm*' \) -print 2>/dev/null || true)"
if [[ -n "$path_matches" ]]; then
  echo "Legacy product identity remains in shipping paths:" >&2
  echo "$path_matches" >&2
  exit 1
fi

echo "Verified RiftVM shipping identity."
