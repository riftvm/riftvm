#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${RUNNER_TEMP:-/tmp}/riftvm-omarchy-release-gates.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
app="$fixture/RiftVM Omarchy.app"
info="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/RiftVM Omarchy"
revision=0123456789abcdef0123456789abcdef01234567
public_key='11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='
entitlement_verifier="$project_root/scripts/verify-omarchy-entitlements.sh"

make_fixture() {
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp /usr/bin/true "$executable"
  plutil -create xml1 "$info"
  plutil -insert CFBundleExecutable -string 'RiftVM Omarchy' "$info"
  plutil -insert CFBundleIdentifier -string com.riftvm.app "$info"
  plutil -insert CFBundleName -string 'RiftVM Omarchy' "$info"
  plutil -insert CFBundleIconName -string AppIcon "$info"
  plutil -insert CFBundleIconFile -string AppIcon "$info"
  plutil -insert CFBundlePackageType -string APPL "$info"
  plutil -insert CFBundleShortVersionString -string 0.1.0 "$info"
  plutil -insert CFBundleVersion -string 1 "$info"
  plutil -insert RiftVMOmarchyFactoryPublicKeyBase64 -string "$public_key" "$info"
  plutil -insert RiftVMSourceRevision -string "$revision" "$info"
  plutil -insert RiftVMSourceTreeState -string clean "$info"
  xcrun actool "$project_root/RiftVMOmarchy/Resources/Assets.xcassets" \
    --compile "$app/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 27.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$fixture/icon-info.plist" \
    --warnings --errors --notices >/dev/null
  codesign --force --deep --sign - \
    --entitlements "$project_root/RiftVMOmarchy/Resources/RiftVMOmarchy.entitlements" \
    --timestamp=none "$app" >/dev/null
}

expect_rejection() {
  local label=$1
  if "$project_root/scripts/verify-omarchy-release-app.sh" \
    "$app" 0.1.0 "$revision" clean >/dev/null 2>&1; then
    echo "release verifier accepted $label" >&2
    exit 1
  fi
}

make_fixture
"$project_root/scripts/verify-omarchy-release-app.sh" \
  "$app" 0.1.0 "$revision" clean >/dev/null

rm "$app/Contents/Resources/AppIcon.icns"
expect_rejection 'a missing compiled application icon'

make_fixture
rm "$app/Contents/Resources/Assets.car"
expect_rejection 'a missing compiled application asset catalog'

make_fixture
plutil -replace CFBundleIconName -string WrongIcon "$info"
expect_rejection 'an unexpected application icon declaration'

# Developer ID exports legitimately contain a TeamIdentifier in the code
# signature while retaining only the explicitly requested minimal entitlement.
"$entitlement_verifier" \
  "$project_root/RiftVMOmarchy/Resources/RiftVMOmarchy.entitlements" YPV49M8592
if "$entitlement_verifier" \
  "$project_root/RiftVMOmarchy/Resources/RiftVMOmarchy.entitlements" WRONGTEAM 2>/dev/null; then
  echo "entitlement verifier accepted an unexpected Developer ID team" >&2
  exit 1
fi

development_entitlements="$fixture/development.entitlements"
cp "$project_root/RiftVMOmarchy/Resources/RiftVMOmarchy.entitlements" "$development_entitlements"
/usr/libexec/PlistBuddy -c \
  'Add :com.apple.application-identifier string YPV49M8592.com.riftvm.app' \
  "$development_entitlements"
/usr/libexec/PlistBuddy -c \
  'Add :com.apple.developer.team-identifier string YPV49M8592' \
  "$development_entitlements"
"$entitlement_verifier" "$development_entitlements" YPV49M8592

if RIFTVM_OMARCHY_FACTORY_PUBLIC_KEY_BASE64='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
  "$project_root/scripts/verify-omarchy-release-app.sh" \
    "$app" 0.1.0 "$revision" clean >/dev/null 2>&1; then
  echo "release verifier accepted a candidate from another factory trust root" >&2
  exit 1
fi

plutil -replace CFBundleIdentifier -string com.riftvm.app "$info"
expect_rejection 'the general RiftVM bundle identifier'

make_fixture
plutil -replace RiftVMOmarchyFactoryPublicKeyBase64 -string invalid "$info"
expect_rejection 'a malformed factory public key'

make_fixture
extra_entitlements="$fixture/extra.entitlements"
cp "$project_root/RiftVMOmarchy/Resources/RiftVMOmarchy.entitlements" "$extra_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.developer.networking.vmnet bool true' "$extra_entitlements"
codesign --force --deep --sign - --entitlements "$extra_entitlements" --timestamp=none "$app" >/dev/null
expect_rejection 'an undeclared VMNet entitlement'
