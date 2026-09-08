#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
output_dir="${2:-$project_root/dist}"
derived_data="${RIFTVM_DERIVED_DATA:-}"
archive_name="RiftVM-${version}.zip"
source_revision="$(git -C "$project_root" rev-parse HEAD)"
source_tree_state="clean"
if [[ -n "$(git -C "$project_root" status --porcelain)" ]]; then
  source_tree_state="dirty"
fi

if [[ -z "$version" ]]; then
  echo "usage: $0 <version> [output-directory]" >&2
  exit 64
fi

if [[ "$version" == v* ]]; then
  version="${version#v}"
  archive_name="RiftVM-${version}.zip"
fi

mkdir -p "$output_dir"

if [[ -z "$derived_data" ]]; then
  derived_data="$(mktemp -d "${RUNNER_TEMP:-/tmp}/riftvm-release-derived-data.XXXXXX")"
fi

# Never reuse a release build directory. A notarization ticket stapled to a
# previous build lives at Contents/CodeResources; Xcode does not remove it on
# an incremental rebuild, and signing an app containing that stale ticket
# produces an archive that Gatekeeper rejects.
if [[ -e "$derived_data/Build/Products/Release/RiftVM.app" ]]; then
  echo "release derived data must be empty: $derived_data" >&2
  exit 65
fi

mkdir -p "$derived_data"

if [[ -n "${RIFTVM_VIRGL_RUNTIME_SOURCE:-}" ]]; then
  virgl_runtime_source="$RIFTVM_VIRGL_RUNTIME_SOURCE"
  case "$virgl_runtime_source" in
    /*) ;;
    *) echo "RIFTVM_VIRGL_RUNTIME_SOURCE must be an absolute path" >&2; exit 67 ;;
  esac
  [[ -d "$virgl_runtime_source" && ! -L "$virgl_runtime_source" ]] || {
    echo "invalid source-qualified VirGL runtime: $virgl_runtime_source" >&2
    exit 67
  }
else
  virgl_runtime_source="$project_root/.build/virgl-runtime-source"
fi

xcodebuild \
  -project "$project_root/RiftVM/RiftVM.xcodeproj" \
  -scheme RiftVM \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  ENABLE_CODE_COVERAGE=NO \
  RIFTVM_SOURCE_REVISION="$source_revision" \
  RIFTVM_SOURCE_TREE_STATE="$source_tree_state" \
  MARKETING_VERSION="$version" \
  build
app_path="$derived_data/Build/Products/Release/RiftVM.app"
if [[ -z "${RIFTVM_VIRGL_RUNTIME_SOURCE:-}" ]]; then
  (cd "$project_root" && \
    "$project_root/scripts/build-virgl-runtime-from-source.sh" "$virgl_runtime_source")
fi
virgl_runtime_destination="$app_path/Contents/Frameworks/VirGLRuntime"
mkdir -p "$virgl_runtime_destination"
ditto "$virgl_runtime_source" "$virgl_runtime_destination"
"$project_root/scripts/verify-virgl-runtime.sh" "$virgl_runtime_destination"
mkdir -p "$app_path/Contents/Resources/ThirdPartyLicenses"
ditto "$project_root/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto "$project_root/ThirdPartyLicenses" "$app_path/Contents/Resources/ThirdPartyLicenses"
(cd "$project_root" && swift build -c release --product riftvm --disable-sandbox)
cli_bin_dir="$(cd "$project_root" && swift build -c release --disable-sandbox --show-bin-path)"
cli_path="$cli_bin_dir/riftvm"
[[ -x "$cli_path" ]] || { echo "CLI executable not found: $cli_path" >&2; exit 66; }
mkdir -p "$app_path/Contents/Helpers"
cp "$cli_path" "$app_path/Contents/Helpers/riftvm"
chmod 755 "$app_path/Contents/Helpers/riftvm"

if [[ -n "${RIFTVM_SIGNING_IDENTITY:-}" ]]; then
  signing_identity="$RIFTVM_SIGNING_IDENTITY"
else
  signing_identity="-"
fi
entitlements_path="$project_root/RiftVM/RiftVM/RiftVM.entitlements"

find_direct_provisioning_profile() {
  local newest=""
  local candidate
  for candidate in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile; do
    [[ -f "$candidate" ]] || continue
    if strings "$candidate" | grep -Fqx '<string>Mac Team Direct Provisioning Profile: com.riftvm.app</string>' &&
       strings "$candidate" | grep -Fqx '<string>YPV49M8592.com.riftvm.app</string>' &&
       strings "$candidate" | grep -Fqx '<key>ProvisionsAllDevices</key>'; then
      if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
        newest="$candidate"
      fi
    fi
  done
  printf '%s\n' "$newest"
}

if [[ "$signing_identity" != "-" ]]; then
  provisioning_profile="${RIFTVM_PROVISIONING_PROFILE:-$(find_direct_provisioning_profile)}"
  [[ -f "$provisioning_profile" ]] || {
    echo "RiftVM Developer ID provisioning profile was not found." >&2
    echo "Export a Developer ID archive in Xcode or set RIFTVM_PROVISIONING_PROFILE." >&2
    exit 68
  }
  strings "$provisioning_profile" | grep -Fqx '<string>YPV49M8592.com.riftvm.app</string>' || {
    echo "Provisioning profile does not match YPV49M8592.com.riftvm.app: $provisioning_profile" >&2
    exit 68
  }
  strings "$provisioning_profile" | grep -Fqx '<key>ProvisionsAllDevices</key>' || {
    echo "Provisioning profile is not a Developer ID distribution profile: $provisioning_profile" >&2
    exit 68
  }
  ditto "$provisioning_profile" "$app_path/Contents/embedded.provisionprofile"
fi

signing_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" == "-" ]]; then
  signing_options+=(--entitlements "$entitlements_path")
  signing_options+=(--timestamp=none)
else
  signing_options+=(--entitlements "$entitlements_path")
  signing_options+=(--options runtime --timestamp)
fi

virgl_signing_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" == "-" ]]; then
  virgl_signing_options+=(--timestamp=none)
else
  virgl_signing_options+=(--options runtime --timestamp)
fi
for library in "$virgl_runtime_destination"/*.dylib; do
  codesign "${virgl_signing_options[@]}" "$library"
done
codesign "${virgl_signing_options[@]}" "$app_path/Contents/Helpers/riftvm"
"$project_root/scripts/verify-virgl-runtime.sh" "$virgl_runtime_destination"
codesign "${signing_options[@]}" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --display --entitlements :- "$app_path"
"$project_root/scripts/verify-release-metadata.sh" \
  "$app_path" "$version" "$source_revision" "$source_tree_state"

if [[ "$signing_identity" != "-" ]]; then
  [[ -f "$app_path/Contents/embedded.provisionprofile" ]] || {
    echo "Developer ID build is missing its embedded provisioning profile." >&2
    exit 68
  }
  app_team_id="$(codesign --display --verbose=4 "$app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ -n "$app_team_id" ]] || {
    echo "Developer ID build has no TeamIdentifier: $app_path" >&2
    exit 68
  }
  for signed_code in "$app_path/Contents/Helpers/riftvm" "$virgl_runtime_destination"/*.dylib; do
    nested_team_id="$(codesign --display --verbose=4 "$signed_code" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$nested_team_id" == "$app_team_id" ]] || {
      echo "TeamIdentifier mismatch: app=$app_team_id nested=${nested_team_id:-missing} path=$signed_code" >&2
      exit 68
    }
  done
  echo "Verified Developer ID TeamIdentifier $app_team_id across app, CLI, and VirGL runtime."
fi

# Fail before archiving if a restricted or accidental entitlement enters the
# production target. Runtime launch and Gatekeeper checks run after notarization.
"$project_root/scripts/verify-production-entitlements.sh" "$app_path"
if otool -l "$app_path/Contents/MacOS/RiftVM" | grep -Eq '__llvm_prf|__llvm_cov'; then
  echo "RiftVM release executable contains coverage instrumentation." >&2
  exit 68
fi
cli_entitlements="$(codesign --display --entitlements - "$app_path/Contents/Helpers/riftvm" 2>/dev/null || true)"
[[ -z "$cli_entitlements" || "$cli_entitlements" == "[Dict]" ]] || {
  echo "RiftVM CLI must not inherit the app's restricted entitlements." >&2
  printf '%s\n' "$cli_entitlements" >&2
  exit 68
}
"$project_root/scripts/verify-virgl-runtime.sh" "$app_path"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_dir/$archive_name"

# Verify the exact archive users will install, not only the pre-archive app.
roundtrip_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/riftvm-release-roundtrip.XXXXXX")"
trap 'rm -rf "$roundtrip_dir"' EXIT
ditto -x -k "$output_dir/$archive_name" "$roundtrip_dir"
codesign --verify --deep --strict --verbose=2 "$roundtrip_dir/RiftVM.app"
(
  cd "$output_dir"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)

echo "Created $output_dir/$archive_name"
