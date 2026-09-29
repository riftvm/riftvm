#!/bin/bash

set -euo pipefail

# Exercises scripts/sync-checked-in-cask.sh against throwaway repositories, so
# the release follow-up commit is checked without touching this checkout or any
# real remote.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$project_root/scripts/lib/common.sh"
sync="$project_root/scripts/sync-checked-in-cask.sh"
work="$(riftvm_mktemp_dir riftvm-cask-sync-test)"
trap 'rm -rf "$work"' EXIT

# Keep the developer's Git configuration, hooks, and signing setup out of it.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="RiftVM Test" GIT_AUTHOR_EMAIL="test@riftvm.invalid"
export GIT_COMMITTER_NAME="RiftVM Test" GIT_COMMITTER_EMAIL="test@riftvm.invalid"
export GIT_TERMINAL_PROMPT=0
unset RIFTVM_RELEASE_BRANCH

old_digest=1111111111111111111111111111111111111111111111111111111111111111
new_digest=2222222222222222222222222222222222222222222222222222222222222222

write_cask() {
  # write_cask <path> <version> <digest>
  sed -e "s/version \"[^\"]*\"/version \"$2\"/" \
      -e "s/sha256 \"[^\"]*\"/sha256 \"$3\"/" \
      "$project_root/Casks/riftvm.rb" >"$1"
}

new_checkout() {
  # new_checkout <name>: a bare origin and a clone of it holding the old cask.
  local name="$1"
  git init -q --bare "$work/$name-origin.git"
  git init -q "$work/$name"
  git -C "$work/$name" checkout -q -b main
  mkdir -p "$work/$name/Casks"
  write_cask "$work/$name/Casks/riftvm.rb" 9.9.8 "$old_digest"
  git -C "$work/$name" add Casks/riftvm.rb
  git -C "$work/$name" commit -q -m "Prepare RiftVM 9.9.9 (build 1)"
  git -C "$work/$name" remote add origin "$work/$name-origin.git"
  git -C "$work/$name" push -q origin main
}

run_sync() {
  # run_sync <checkout> <version> <cask>
  RIFTVM_CASK_SYNC_PROJECT_ROOT="$work/$1" "$sync" "$2" "$3"
}

assert_clean() {
  [[ -z "$(git -C "$work/$1" status --porcelain)" ]] || fail "$1: the worktree is not clean"
}

commit_count() {
  git -C "$work/$1" rev-list --count HEAD
}

published="$work/published.rb"
write_cask "$published" 9.9.9 "$new_digest"

# A published cask is committed alone and pushed.
new_checkout ok
run_sync ok 9.9.9 "$published" >/dev/null
assert_clean ok
cmp -s "$published" "$work/ok/Casks/riftvm.rb" || fail "the checked-in cask was not updated"
[[ "$(commit_count ok)" == 2 ]] || fail "expected exactly one follow-up commit"
[[ "$(git -C "$work/ok" log -1 --format=%s)" == "chore(cask): sync riftvm cask to 9.9.9" ]] || \
  fail "unexpected follow-up commit subject"
[[ "$(git -C "$work/ok" show --name-only --format= HEAD)" == "Casks/riftvm.rb" ]] || \
  fail "the follow-up commit must contain only Casks/riftvm.rb"
[[ "$(git -C "$work/ok" rev-parse HEAD)" == "$(git -C "$work/ok-origin.git" rev-parse refs/heads/main)" ]] || \
  fail "the follow-up commit was not pushed"

# Running it again changes nothing.
run_sync ok v9.9.9 "$published" >/dev/null
assert_clean ok
[[ "$(commit_count ok)" == 2 ]] || fail "a second run must not commit again"

# A cask for another version is rejected before anything is written.
new_checkout mismatch
if run_sync mismatch 9.9.10 "$published" >/dev/null 2>&1; then
  fail "a cask at the wrong version was accepted"
fi
assert_clean mismatch
[[ "$(commit_count mismatch)" == 1 ]] || fail "a rejected cask must not be committed"

# A cask that is not valid Ruby is rejected.
printf 'cask "riftvm" do\n  version "9.9.9"\n  sha256 "%s"\n' "$new_digest" >"$work/broken.rb"
if run_sync mismatch 9.9.9 "$work/broken.rb" >/dev/null 2>&1; then
  fail "a cask that is not valid Ruby was accepted"
fi
assert_clean mismatch
[[ "$(commit_count mismatch)" == 1 ]] || fail "an invalid cask must not be committed"

# Unrelated local changes are never swept into the commit.
new_checkout dirty
echo note >"$work/dirty/untracked.txt"
if run_sync dirty 9.9.9 "$published" >/dev/null 2>&1; then
  fail "a dirty worktree was accepted"
fi
[[ "$(commit_count dirty)" == 1 ]] || fail "a dirty worktree must not be committed"
[[ "$(git -C "$work/dirty" status --porcelain)" == "?? untracked.txt" ]] || \
  fail "a rejected run must leave the worktree as it found it"

# A failed push reports failure, keeps the commit, and leaves the worktree clean.
new_checkout nopush
git -C "$work/nopush" remote set-url origin "$work/missing-origin.git"
if run_sync nopush 9.9.9 "$published" >/dev/null 2>&1; then
  fail "a failed push was reported as success"
fi
assert_clean nopush
[[ "$(commit_count nopush)" == 2 ]] || fail "the local follow-up commit should survive a failed push"

echo "Checked-in cask sync tests passed."
