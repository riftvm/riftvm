#!/bin/bash

set -euo pipefail

# Every published `riftvm-vX.Y.Z` tag must have a section in docs/RELEASES.md so
# the reason for a release stays reviewable in the source tree. Pass a version
# to require exactly one release; otherwise every release tag is checked.
#
# Releases that predate the convention are listed below. Do not add new tags to
# this list: write the note instead.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
notes_file="${RIFTVM_RELEASE_NOTES_FILE:-$project_root/docs/RELEASES.md}"
requested_version="${1#v}"

# RiftVM version tags that predate the notes convention.
exempt_tags=(
  riftvm-v0.1.0
  riftvm-v0.1.1
  riftvm-v0.1.2
  riftvm-v0.1.3
  riftvm-v0.1.5
  riftvm-v0.1.6
  riftvm-v0.1.7
  riftvm-v0.1.8
  riftvm-v0.1.9
  riftvm-v0.1.10
)

fail() { echo "verify-release-notes: $*" >&2; exit 1; }

[[ -f "$notes_file" && ! -L "$notes_file" ]] || fail "release notes not found: $notes_file"

if [[ -n "$requested_version" ]]; then
  [[ "$requested_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: $0 [major.minor.patch]"
  tags=("riftvm-v$requested_version")
else
  command -v git >/dev/null 2>&1 || fail "git is required to enumerate release tags"
  tags=()
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    tags+=("$tag")
  done < <(git -C "$project_root" tag --list 'riftvm-v[0-9]*.[0-9]*.[0-9]*' --sort=version:refname)
fi

[[ ${#tags[@]} -gt 0 ]] || fail "no release tags to check"

is_exempt() {
  local candidate="$1" exempt
  for exempt in "${exempt_tags[@]}"; do
    [[ "$candidate" == "$exempt" ]] && return 0
  done
  return 1
}

missing=()
for tag in "${tags[@]}"; do
  # An explicitly requested release is never exempt: asking about it means it
  # must be documented.
  if [[ -z "$requested_version" ]] && is_exempt "$tag"; then
    continue
  fi
  version="${tag#riftvm-v}"
  grep -Eq "^## ${version//./\\.}([[:space:]]|\$)" "$notes_file" || missing+=("$tag")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "verify-release-notes: missing a section in $(basename "$notes_file") for: ${missing[*]}" >&2
  echo "Add a '## <version>' section describing what changed and why; see the convention at the top of that file." >&2
  exit 1
fi

echo "Verified release notes for ${#tags[@]} release tag(s)."
