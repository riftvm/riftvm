#!/bin/bash
# Builds a local-only GUI harness. Never archive or distribute this app.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=${1:?usage: build-omarchy-acceptance-harness.sh /tmp/output-directory}
python3 - "$output" <<'PY'
import pathlib,sys,tempfile
p=pathlib.Path(sys.argv[1]).resolve()
roots=[pathlib.Path('/tmp').resolve(),pathlib.Path(tempfile.gettempdir()).resolve()]
if not any(r in p.parents for r in roots):sys.exit('Harness output must be inside temporary storage')
PY
mkdir -p "$output"
app="$output/RiftVM Acceptance.app"
[[ ! -e "$app" ]] || { echo 'Use a fresh harness output directory' >&2; exit 64; }
xcodebuild -quiet -project "$root/RiftVM/RiftVM.xcodeproj" -scheme RiftVM \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$output/DerivedData" CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=RIFTVM_ACCEPTANCE_HARNESS \
  RIFTVM_SOURCE_REVISION="$(git -C "$root" rev-parse HEAD)" RIFTVM_SOURCE_TREE_STATE=dirty build
mv "$output/DerivedData/Build/Products/Release/RiftVM.app" "$app"
runtime=${RIFTVM_VIRGL_RUNTIME_SOURCE:-/Applications/RiftVM.app/Contents/Frameworks/VirGLRuntime}
[[ -d "$runtime" ]] || { echo 'A qualified VirGL runtime is required' >&2; exit 64; }
mkdir -p "$app/Contents/Frameworks/VirGLRuntime"
ditto "$runtime" "$app/Contents/Frameworks/VirGLRuntime"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f:d=plistlib.load(f)
d.update(CFBundleDisplayName='RiftVM Acceptance',CFBundleName='RiftVM Acceptance',RiftVMAcceptanceHarness=True)
with open(p,'wb') as f:plistlib.dump(d,f)
PY
identity=${RIFTVM_SIGNING_IDENTITY:--}
if [[ "$identity" != - ]]; then
  cp /Applications/RiftVM.app/Contents/embedded.provisionprofile "$app/Contents/embedded.provisionprofile"
fi
for library in "$app"/Contents/Frameworks/VirGLRuntime/*.dylib; do
  codesign --force --sign "$identity" --timestamp=none "$library"
done
codesign --force --sign "$identity" --timestamp=none --entitlements "$root/RiftVM/RiftVM/RiftVM.entitlements" "$app"
codesign --verify --deep --strict "$app"
if "$root/scripts/verify-production-test-isolation.sh" "$app"; then
  echo 'Harness unexpectedly passed the production exclusion gate' >&2; exit 1
fi
printf 'Built local-only harness: %s\n' "$app"
