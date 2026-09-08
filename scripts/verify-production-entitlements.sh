#!/bin/bash

set -euo pipefail

app_path="${1:-}"

fail() {
  echo "verify-production-entitlements: $*" >&2
  exit 1
}

[[ -n "$app_path" ]] || fail "usage: $0 <RiftVM.app>"
[[ -d "$app_path" ]] || fail "application not found: $app_path"

entitlements_file="$(mktemp "${TMPDIR:-/tmp}/riftvm-entitlements.XXXXXX")"
cleanup() {
  rm -f "$entitlements_file"
}
trap cleanup EXIT

# Xcode 27's codesign prints a structured [Dict]/[Key]/[Bool] representation
# for `--entitlements -`; older toolchains print an XML plist. Support both.
codesign --display --entitlements - "$app_path" >"$entitlements_file" 2>/dev/null
[[ -s "$entitlements_file" ]] || fail "codesign returned no entitlements"

required_boolean_keys="com.apple.developer.accessory-access.usb
com.apple.developer.networking.vmnet
com.apple.security.virtualization"
profile_keys="com.apple.application-identifier
com.apple.developer.accessory-access.usb
com.apple.developer.networking.vmnet
com.apple.developer.team-identifier
com.apple.security.virtualization"

if grep -q '^\[Dict\]$' "$entitlements_file"; then
  entitlement_keys="$(sed -n 's/^[[:space:]]*\[Key\] //p' "$entitlements_file" | LC_ALL=C sort)"
  [[ "$entitlement_keys" == "$required_boolean_keys" || "$entitlement_keys" == "$profile_keys" ]] || {
    cat "$entitlements_file" >&2
    fail "the release entitlement set does not match the allowlist"
  }
  while IFS= read -r key; do
    grep -A2 "^[[:space:]]*\[Key\] $key$" "$entitlements_file" | \
      grep -q '^[[:space:]]*\[Bool\] true$' || fail "$key is not enabled"
  done <<<"$required_boolean_keys"
  if [[ "$entitlement_keys" == "$profile_keys" ]]; then
    grep -A2 '^[[:space:]]*\[Key\] com.apple.application-identifier$' "$entitlements_file" | \
      grep -q '^[[:space:]]*\[String\] YPV49M8592.com.riftvm.app$' || \
      fail "application identifier does not match the production App ID"
    grep -A2 '^[[:space:]]*\[Key\] com.apple.developer.team-identifier$' "$entitlements_file" | \
      grep -q '^[[:space:]]*\[String\] YPV49M8592$' || fail "team identifier does not match"
  fi
else
  plutil -lint "$entitlements_file" >/dev/null
  entitlement_keys="$(plutil -p "$entitlements_file" | sed -n 's/^  "\([^"]*\)" =>.*/\1/p' | LC_ALL=C sort)"
  [[ "$entitlement_keys" == "$required_boolean_keys" || "$entitlement_keys" == "$profile_keys" ]] || {
    plutil -p "$entitlements_file" >&2
    fail "the release entitlement set does not match the allowlist"
  }
  while IFS= read -r key; do
    value="$(plutil -extract "$key" raw "$entitlements_file")"
    [[ "$value" == "true" ]] || fail "$key is not enabled"
  done <<<"$required_boolean_keys"
  if [[ "$entitlement_keys" == "$profile_keys" ]]; then
    application_identifier="$(plutil -extract com.apple.application-identifier raw "$entitlements_file")"
    [[ "$application_identifier" == "YPV49M8592.com.riftvm.app" ]] || \
      fail "application identifier does not match the production App ID"
    embedded_team_identifier="$(plutil -extract com.apple.developer.team-identifier raw "$entitlements_file")"
    [[ "$embedded_team_identifier" == "YPV49M8592" ]] || fail "team identifier does not match"
  fi
fi

echo "Verified production entitlement allowlist."
