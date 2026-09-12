#!/bin/bash

set -euo pipefail

# Unit test for the generated release changelog. Builds a throwaway repository so
# the wording rules can be checked without touching this checkout.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
notes_script="$project_root/scripts/release-notes.sh"

fail() { echo "test-release-notes: $*" >&2; exit 1; }

[[ -x "$notes_script" ]] || fail "release notes script not executable: $notes_script"

# The script writes relative to its own location, so a mistake here edits this
# checkout instead of the scratch repository. Compare against the starting state
# so uncommitted work in progress does not confuse the check.
checkout_state="$(git -C "$project_root" status --porcelain -- docs scripts)"

work="$(mktemp -d "${TMPDIR:-/tmp}/riftvm-release-notes-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

repo="$work/repo"
mkdir -p "$repo/scripts" "$repo/docs"
cp "$notes_script" "$repo/scripts/"
cat > "$repo/docs/RELEASES.md" <<'MARKDOWN'
# Release notes

## Where notes live

Text.

## How to write a release note

Text.

## 0.1.14

The previous release.
MARKDOWN

cd "$repo"
git init -q .
git config user.email test@example.invalid
git config user.name "RiftVM Test"
git add -A
git commit -qm "Record the release note convention"
git tag -a riftvm-v0.1.14 -m "RiftVM 0.1.14"

# Always run the copy inside the scratch repository: the script writes relative
# to its own location, so using the checkout's copy would edit this repository.
notes() { "$repo/scripts/release-notes.sh" "$@"; }

commit() {
  local subject="$1" body="${2:-}" extra="${3:-}"
  printf '%s\n' "$subject" >> "$repo/changes.txt"
  git add -A
  if [[ -n "$body" ]]; then
    git commit -qm "$subject" -m "$body" ${extra:+"$extra"}
  else
    git commit -qm "$subject" ${extra:+"$extra"}
  fi
}

section() {
  awk -v start="## $1" -v stop="## $2" \
    'index($0, start) == 1 { flag = 1 } index($0, stop) == 1 { flag = 0 } flag' \
    "$repo/docs/RELEASES.md"
}

commit "feat: add a portable import picker" "The picker refuses packages from a different schema
version instead of failing later."
commit "fix(catalog): point the Linux catalog at riftvm.com" "The old host answered 404, so the list never refreshed."
commit "perf: keep display frames updating without pointer movement"
commit "refactor: drop the retired sparse image decoder"
commit "Keep background VM Command shortcuts in the foreground host app"
commit "Prepare RiftVM 0.1.15 (build 15)"

notes prepare 0.1.15 >/dev/null
generated="$(section "0.1.15" "0.1.14")"

# Grouping by conventional-commit prefix, with unprefixed commits kept.
grep -Fq "### Features" <<<"$generated" || fail "a feature was not grouped"
grep -Fq "### Fixes" <<<"$generated" || fail "a fix was not grouped"
grep -Fq "### Performance" <<<"$generated" || fail "a performance change was not grouped"
grep -Fq "### Internal" <<<"$generated" || fail "an internal change was not grouped"
grep -Fq "### Changes" <<<"$generated" || fail "an unprefixed change was dropped"
grep -Fq -- "- Add a portable import picker" <<<"$generated" || fail "feature bullet missing"
grep -Fq -- "- Point the Linux catalog at riftvm.com" <<<"$generated" || fail "fix bullet missing"
grep -Fq -- "- Keep background VM Command shortcuts in the foreground host app" <<<"$generated" \
  || fail "unprefixed commit missing"
grep -Fq -- "- Drop the retired sparse image decoder" <<<"$generated" || fail "internal change missing"

# The commit body is the motivation and must survive into the bullet.
grep -Fq "The old host answered 404, so the list never refreshed." <<<"$generated" \
  || fail "commit body motivation was dropped"

# A soft-wrapped body must be read as one sentence, not cut at the first line.
grep -Fq -- "— The picker refuses packages from a different schema version instead of failing later." <<<"$generated" \
  || fail "a soft-wrapped commit body was truncated"

# Version preparation commits are not release notes.
if grep -Fq "Prepare RiftVM" <<<"$generated"; then
  fail "a version preparation commit leaked into the changelog"
fi

# A written section is never overwritten.
before="$(cat "$repo/docs/RELEASES.md")"
notes prepare 0.1.15 >/dev/null
[[ "$(cat "$repo/docs/RELEASES.md")" == "$before" ]] || fail "prepare rewrote an existing section"

# A release is tagged before the next one is prepared; that tag is what fixes the
# baseline for the following changelog.
git tag -a riftvm-v0.1.15 -m "RiftVM 0.1.15"

# The published body strips the draft marker, makes links absolute, and carries
# the install instructions.
commit "docs: link the release note convention" "See [P0 validation](P0_VALIDATION.md) for the open input findings."
commit "Prepare RiftVM 0.1.16 (build 16)" "" "--allow-empty"
git tag -a riftvm-v0.1.16 -m "RiftVM 0.1.16"
notes prepare 0.1.16 >/dev/null
body="$(notes extract 0.1.16)"
if grep -Fq "<!-- draft" <<<"$body"; then
  fail "the published body kept the draft marker"
fi
grep -Fq "https://github.com/riftvm/riftvm/blob/main/docs/P0_VALIDATION.md" <<<"$body" \
  || fail "relative documentation links were not made absolute"
grep -Fq "brew install --cask riftvm/tap/riftvm" <<<"$body" || fail "install instructions missing"
grep -Eq '^RiftVM|^Requires' <<<"$body" || fail "published body lost its structure"

# check passes for a repository whose releases all have sections.
notes check >/dev/null || fail "check reported a missing section for a covered release"

# The scratch repository must be the only thing this test touched.
[[ "$(git -C "$project_root" status --porcelain -- docs scripts)" == "$checkout_state" ]] \
  || fail "the test modified the checkout: $(git -C "$project_root" status --porcelain -- docs scripts | head -3)"

echo "Verified generated release changelog grouping, wording, and extraction."
