#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
tap_repo="${RIFTVM_HOMEBREW_TAP:-git@github.com:riftvm/homebrew-tap.git}"
release_repo="${RIFTVM_RELEASE_REPOSITORY:-riftvm/riftvm}"
release_branch="${RIFTVM_RELEASE_BRANCH:-main}"

if [[ -z "$version" ]]; then
  echo "usage: $0 <version>" >&2
  exit 64
fi

version="${version#v}"
tag="riftvm-v$version"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 69
  fi
}

require_environment() {
  if [[ -z "${!1:-}" ]]; then
    echo "required environment variable is missing: $1" >&2
    exit 78
  fi
}

for command in brew codesign gh git go ruby security xcrun; do
  require_command "$command"
done

require_environment APPLE_ID
require_environment APPLE_TEAM_ID
require_environment APPLE_SPECIFIC_PASSWORD

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI authentication is invalid. Run: gh auth login -h github.com" >&2
  exit 77
fi

signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
if [[ -z "$signing_identity" ]]; then
  echo "No Developer ID Application identity is available in the keychain." >&2
  echo "Import the certificate and private key before publishing." >&2
  exit 78
fi

if [[ -n "$(git -C "$project_root" status --porcelain)" ]]; then
  echo "The worktree must be clean before publishing." >&2
  exit 65
fi

tag_commit="$(git -C "$project_root" rev-list -n 1 "$tag" 2>/dev/null || true)"
head_commit="$(git -C "$project_root" rev-parse HEAD)"
if [[ -z "$tag_commit" || "$tag_commit" != "$head_commit" ]]; then
  echo "$tag must exist and point at HEAD before publishing." >&2
  exit 65
fi

state_base="${RIFTVM_RELEASE_STATE_DIR:-${TMPDIR:-/tmp}/riftvm-release-state}"
release_dir="$state_base/$version"
tap_dir="$(mktemp -d /tmp/riftvm-tap.XXXXXX)"
derived_data="$release_dir/DerivedData"
cleanup() {
  rm -rf "$tap_dir"
}
trap cleanup EXIT
mkdir -p "$release_dir"

archive="$release_dir/RiftVM-$version.zip"
checksum="$archive.sha256"
guest_archive="$release_dir/RiftVM-GuestAgent-$version-linux-arm64.tar.gz"
guest_checksum="$guest_archive.sha256"
source_commit_file="$release_dir/source-commit"
source_commit="$(git -C "$project_root" rev-parse HEAD)"

if [[ -f "$source_commit_file" && "$(tr -d '\r\n' <"$source_commit_file")" == "$source_commit" && \
      -f "$archive" && -f "$checksum" && -f "$guest_archive" && -f "$guest_checksum" ]] && \
   (cd "$release_dir" && shasum -a 256 -c "$(basename "$checksum")" "$(basename "$guest_checksum")"); then
  echo "Reusing verified RiftVM $version release artifacts from $release_dir"
else
  rm -f "$archive" "$checksum" "$guest_archive" "$guest_checksum" \
    "$release_dir/notarized" "$release_dir/stapled" "$source_commit_file"
  rm -rf "$derived_data"
  RIFTVM_SIGNING_IDENTITY="$signing_identity" \
  RIFTVM_DERIVED_DATA="$derived_data" \
    "$project_root/scripts/build-release.sh" "$version" "$release_dir"
  "$project_root/scripts/build-guest-agent.sh" "$version" "$release_dir"
  printf '%s\n' "$source_commit" >"$source_commit_file"
fi

if [[ ! -f "$release_dir/notarized" ]]; then
  xcrun notarytool submit "$archive" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_SPECIFIC_PASSWORD" \
    --wait
  touch "$release_dir/notarized"
fi

# Keep the release self-contained. A stapled ticket lets Gatekeeper validate
# RiftVM when the destination Mac is offline. Rebuild the ZIP only once so a
# resumed release preserves the checksum that will be published and used by
# Homebrew.
if [[ ! -f "$release_dir/stapled" ]]; then
  staple_dir="$release_dir/staple"
  rm -rf "$staple_dir"
  mkdir -p "$staple_dir"
  ditto -x -k "$archive" "$staple_dir"
  staple_status=1
  for attempt in {1..12}; do
    if xcrun stapler staple "$staple_dir/RiftVM.app"; then
      staple_status=0
      break
    fi
    if [[ $attempt -lt 12 ]]; then
      echo "Notarization ticket is not available yet; retrying staple ($attempt/12)…" >&2
      sleep 10
    fi
  done
  [[ $staple_status -eq 0 ]] || {
    echo "Apple accepted the submission but its stapling ticket did not become available." >&2
    exit 69
  }
  xcrun stapler validate "$staple_dir/RiftVM.app"
  codesign --verify --deep --strict --verbose=2 "$staple_dir/RiftVM.app"
  rm -f "$archive" "$checksum"
  ditto -c -k --sequesterRsrc --keepParent "$staple_dir/RiftVM.app" "$archive"
  (cd "$release_dir" && shasum -a 256 "$(basename "$archive")" >"$(basename "$checksum")")
  touch "$release_dir/stapled"
fi

install_check_dir="$release_dir/install-check"
rm -rf "$install_check_dir"
mkdir -p "$install_check_dir"
ditto -x -k "$archive" "$install_check_dir"
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");RiftVMRelease;" "$install_check_dir/RiftVM.app"
codesign --verify --deep --strict --verbose=2 "$install_check_dir/RiftVM.app"
spctl --assess --type execute --verbose=4 "$install_check_dir/RiftVM.app"
RIFTVM_LAUNCH_TIMEOUT="${RIFTVM_LAUNCH_TIMEOUT:-10}" \
  "$project_root/scripts/verify-release-app.sh" \
    "$install_check_dir/RiftVM.app" "$version" "$source_commit"
if [[ -n "${RIFTVM_RELEASE_SMOKE_VM:-}" ]]; then
  RIFTVM_VM_SMOKE_TIMEOUT="${RIFTVM_VM_SMOKE_TIMEOUT:-90}" \
  RIFTVM_RELEASE_SMOKE_ENROLLMENT="${RIFTVM_RELEASE_SMOKE_ENROLLMENT:-}" \
    "$project_root/scripts/verify-release-cli.sh" "$install_check_dir/RiftVM.app" "$RIFTVM_RELEASE_SMOKE_VM"
  RIFTVM_VM_SMOKE_TIMEOUT="${RIFTVM_VM_SMOKE_TIMEOUT:-90}" \
  RIFTVM_RELEASE_SMOKE_ENROLLMENT="${RIFTVM_RELEASE_SMOKE_ENROLLMENT:-}" \
    "$project_root/scripts/verify-release-nested-virtualization.sh" "$install_check_dir/RiftVM.app" "$RIFTVM_RELEASE_SMOKE_VM"
  RIFTVM_VM_SMOKE_TIMEOUT="${RIFTVM_VM_SMOKE_TIMEOUT:-90}" \
  RIFTVM_RELEASE_SMOKE_ENROLLMENT="${RIFTVM_RELEASE_SMOKE_ENROLLMENT:-}" \
    "$project_root/scripts/verify-release-vm.sh" "$install_check_dir/RiftVM.app" "$RIFTVM_RELEASE_SMOKE_VM"
fi
if [[ -n ${RIFTVM_RELEASE_PREINSTALLED_MANIFEST:-} || -n ${RIFTVM_RELEASE_PREINSTALLED_IMAGE:-} ]]; then
  [[ -n ${RIFTVM_RELEASE_PREINSTALLED_MANIFEST:-} && -n ${RIFTVM_RELEASE_PREINSTALLED_IMAGE:-} ]] || {
    echo "RIFTVM_RELEASE_PREINSTALLED_MANIFEST and RIFTVM_RELEASE_PREINSTALLED_IMAGE must be set together." >&2
    exit 78
  }
  RIFTVM_APP_PATH="$install_check_dir/RiftVM.app" \
    "$project_root/scripts/verify-homebrew-preinstalled-image.sh" \
    "$RIFTVM_RELEASE_PREINSTALLED_MANIFEST" "$RIFTVM_RELEASE_PREINSTALLED_IMAGE"
fi
if [[ -z ${RIFTVM_RELEASE_SMOKE_VM:-} && -z ${RIFTVM_RELEASE_PREINSTALLED_IMAGE:-} ]]; then
  echo "A standard smoke VM or preinstalled-image fixture is required for a release VM boot test." >&2
  exit 78
fi

# Publish refs only after the exact candidate has passed notarization,
# Gatekeeper, GUI readiness, and all real-VM tests.
git -C "$project_root" push origin "HEAD:refs/heads/$release_branch" "refs/tags/$tag"

if gh release view "$tag" --repo "$release_repo" >/dev/null 2>&1; then
  published_checksums="$release_dir/published-checksums"
  rm -rf "$published_checksums"
  mkdir -p "$published_checksums"
  gh release download "$tag" --repo "$release_repo" --pattern '*.sha256' --dir "$published_checksums"
  cmp -s "$checksum" "$published_checksums/$(basename "$checksum")" || {
    echo "Existing GitHub release has a different RiftVM checksum." >&2; exit 67;
  }
  cmp -s "$guest_checksum" "$published_checksums/$(basename "$guest_checksum")" || {
    echo "Existing GitHub release has a different Guest Agent checksum." >&2; exit 67;
  }
  echo "GitHub release $tag already contains the verified artifacts; continuing."
else
  gh release create "$tag" "$archive" "$checksum" "$guest_archive" "$guest_checksum" \
    --repo "$release_repo" \
    --verify-tag \
    --generate-notes \
    --title "RiftVM $version"
fi

# Replace the generated changelog with the note tracked in docs/RELEASES.md.
# Releasing is never blocked by notes, so a missing section only means this step
# is skipped. Other repositories may not carry the file at all.
if [[ "$release_repo" == "riftvm/riftvm" && -f "$project_root/docs/RELEASES.md" ]]; then
  notes_file="$release_dir/release-notes.md"
  if "$project_root/scripts/release-notes.sh" extract "$version" >"$notes_file" 2>"$release_dir/release-notes-error"; then
    if gh release edit "$tag" --repo "$release_repo" --notes-file "$notes_file"; then
      echo "Published release notes for $tag from docs/RELEASES.md."
    else
      echo "Could not set release notes for $tag; leaving the generated notes in place." >&2
    fi
  else
    cat "$release_dir/release-notes-error" >&2
    echo "No release note section for $version; leaving the generated notes in place." >&2
  fi
fi

git clone "$tap_repo" "$tap_dir/repository"
ruby "$project_root/scripts/update-cask.rb" \
  "$version" \
  "$archive" \
  "$project_root/Casks/riftvm.rb" \
  "$tap_dir/repository/Casks/riftvm.rb"

ruby -c "$tap_dir/repository/Casks/riftvm.rb"
git -C "$tap_dir/repository" add Casks/riftvm.rb
git -C "$tap_dir/repository" diff --cached --quiet || \
  git -C "$tap_dir/repository" commit -m "Update RiftVM to $version"
git -C "$tap_dir/repository" push

"$project_root/scripts/verify-homebrew-release.sh" \
  "$version" "${RIFTVM_RELEASE_SMOKE_VM:-}" "$source_commit"

echo "Published RiftVM $version to GitHub Releases and Homebrew."
