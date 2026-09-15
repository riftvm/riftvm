#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-}"
manifest_source="${2:-}"
profile_file="$project_root/RiftVM/RiftVM/Core/VMKit/Profile/VMOmarchyProfile.swift"

fail() { printf 'verify-factory-trust: %s\n' "$*" >&2; exit 1; }

[[ -d "$app_path" ]] || fail "usage: $0 <RiftVM.app> [factory-manifest-url-or-path]"
info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail "the app has no Info.plist: $app_path"

for command in base64 curl jq plutil swift; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

# The manifest the shipped app will fetch. Read it out of the profile so this
# check cannot drift from the app: a URL change is picked up automatically.
if [[ -z "$manifest_source" ]]; then
  manifest_urls="$(grep -oE 'https://[^"]*riftvm-omarchy-factory-manifest\.json' "$profile_file" | sort -u)"
  manifest_count="$(printf '%s\n' "$manifest_urls" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "$manifest_count" -eq 1 ]] || \
    fail "expected exactly one pinned factory manifest URL in VMOmarchyProfile.swift, found $manifest_count"
  manifest_source="$manifest_urls"
fi

# Trust anchors come from the built app, so the check is against what users
# actually receive rather than against the source template.
encoded_keys="$(
  plutil -convert json -o - "$info_plist" \
    | jq -r '(.RiftVMOmarchyFactoryPublicKeysBase64 // [])[]'
)"
[[ -n "$encoded_keys" ]] || fail "the app carries no RiftVMOmarchyFactoryPublicKeysBase64 entries"

work="$(mktemp -d "${TMPDIR:-/tmp}/riftvm-factory-trust.XXXXXX")"
trap 'rm -rf "$work"' EXIT

case "$manifest_source" in
  http://*|https://*)
    manifest="$work/manifest.json"
    curl --no-progress-meter --fail --location --retry 3 --retry-delay 3 \
      --connect-timeout 30 -o "$manifest" "$manifest_source" \
      || fail "could not download $manifest_source"
    ;;
  *)
    manifest="$manifest_source"
    [[ -f "$manifest" ]] || fail "manifest not found: $manifest"
    ;;
esac

decoded_keys=()
index=0
while IFS= read -r encoded; do
  [[ -n "$encoded" ]] || continue
  key_file="$work/key-$index.bin"
  if ! printf '%s' "$encoded" | base64 --decode >"$key_file" 2>/dev/null; then
    printf '%s' "$encoded" | base64 -D >"$key_file" 2>/dev/null \
      || fail "trusted key $index is not valid base64"
  fi
  key_bytes="$(stat -f %z "$key_file")"
  [[ "$key_bytes" == 32 ]] || fail "trusted key $index is $key_bytes bytes, expected 32"
  decoded_keys+=("$key_file")
  index=$((index + 1))
done <<< "$encoded_keys"

# Fails unless one of the configured keys signed this manifest, which is the
# same decision the app makes when a user creates an Omarchy workspace.
swift run --package-path "$project_root" -c release omarchy-factory-tool \
  verify-manifest "$manifest" "${decoded_keys[@]}" \
  || fail "no configured key verifies $manifest_source; the app would reject it as an invalid signature"

printf 'verify-factory-trust: %s verifies against %d configured key(s)\n' \
  "$manifest_source" "${#decoded_keys[@]}"
