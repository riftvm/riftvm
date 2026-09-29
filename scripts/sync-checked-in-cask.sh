#!/bin/bash

set -euo pipefail

# Copies the cask that was just published to the Homebrew tap back into this
# repository's Casks/riftvm.rb, commits it, and pushes that one commit.
#
# scripts/publish-release.sh runs this as its last step. The archive digest is
# only known after notarization and stapling, which happen after the release
# commit is tagged, so the checked-in cask can only follow in a separate commit.
# Running it again for a cask that is already checked in changes nothing.
#
# The commit contains Casks/riftvm.rb and nothing else. On any failure the
# worktree is left clean, so a later release is never blocked by this script.

project_root="${RIFTVM_CASK_SYNC_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
version="${1:-}"
published_cask="${2:-}"
release_branch="${RIFTVM_RELEASE_BRANCH:-main}"
checked_in_cask="$project_root/Casks/riftvm.rb"

fail() {
  echo "sync-checked-in-cask: $*" >&2
  exit 1
}

[[ -n "$version" && -n "$published_cask" ]] || fail "usage: $0 <version> <published-cask-file>"
version="${version#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be major.minor.patch: $version"
[[ -f "$published_cask" ]] || fail "published cask not found: $published_cask"
[[ -f "$checked_in_cask" ]] || fail "checked-in cask not found: $checked_in_cask"
for command in git ruby; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

ruby -c "$published_cask" >/dev/null || fail "published cask is not valid Ruby: $published_cask"
grep -qF "version \"$version\"" "$published_cask" || \
  fail "published cask is not at version $version: $published_cask"
grep -qE 'sha256 "[0-9a-f]{64}"' "$published_cask" || \
  fail "published cask has no SHA-256 digest: $published_cask"

if cmp -s "$published_cask" "$checked_in_cask"; then
  echo "Casks/riftvm.rb is already at RiftVM $version."
  exit 0
fi

[[ -z "$(git -C "$project_root" status --porcelain)" ]] || \
  fail "the worktree must be clean before syncing the checked-in cask"

restore() {
  git -C "$project_root" reset -q -- Casks/riftvm.rb >/dev/null 2>&1 || true
  git -C "$project_root" checkout -q -- Casks/riftvm.rb >/dev/null 2>&1 || true
}

cp "$published_cask" "$checked_in_cask" || { restore; fail "could not write $checked_in_cask"; }
git -C "$project_root" add -- Casks/riftvm.rb || { restore; fail "could not stage Casks/riftvm.rb"; }
git -C "$project_root" commit -m "chore(cask): sync riftvm cask to $version" -- Casks/riftvm.rb || {
  restore
  fail "could not commit Casks/riftvm.rb"
}

git -C "$project_root" push origin "HEAD:refs/heads/$release_branch" || \
  fail "committed the cask locally but could not push it; run: git push origin HEAD:refs/heads/$release_branch"

echo "Synced Casks/riftvm.rb to RiftVM $version and pushed it to $release_branch."
