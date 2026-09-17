#!/bin/bash

set -euo pipefail

manifest=${1:-}
image=${2:-}
timeout=${RIFTVM_PREINSTALLED_SMOKE_TIMEOUT:-180}
app_path=${RIFTVM_APP_PATH:-/Applications/RiftVM.app}

fail() { echo "verify-homebrew-preinstalled-image: $*" >&2; exit 1; }

[[ -f $manifest && -f $image ]] || fail "usage: $0 <preinstalled-image-manifest.json> <decoded-disk.raw>"
# The CLI rejects a timeout above its own bound, so an out-of-range value must
# fail here with the reason instead of inside a captured helper call.
[[ $timeout =~ ^[1-9][0-9]*$ && $timeout -le 300 ]] ||
  fail "RIFTVM_PREINSTALLED_SMOKE_TIMEOUT must be between 1 and 300 seconds"
[[ -d $app_path ]] || fail "RiftVM app was not found: $app_path"
cli="$app_path/Contents/Helpers/riftvm"
[[ -x $cli ]] || fail "the RiftVM CLI is missing from $app_path"

work=$(mktemp -d /tmp/riftvm-preinstalled-e2e.XXXXXX)
destination="$work/Preinstalled Smoke.riftvm"
started=0
cleanup() {
  if ((started)); then "$cli" stop "$destination" --timeout 30 >/dev/null 2>&1 || true; fi
  if [[ ${RIFTVM_KEEP_SMOKE_ARTIFACTS:-0} == 1 ]]; then
    echo "verify-homebrew-preinstalled-image: retained $work" >&2
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT INT TERM

# A helper that exits non-zero still prints its JSON diagnosis, so keep that
# output instead of letting `set -e` replace it with a bare exit status.
install_result=$(
  "$cli" install-image "$manifest" --image "$image" --destination "$destination" \
    --name "Preinstalled Image Smoke" --timeout "$timeout" 2>&1
) || fail "install-image failed: ${install_result:-no output}"
jq -e '.success == true and .command == "install-image"' <<<"$install_result" >/dev/null ||
  fail "install-image did not report success: $install_result"

validate_result=$("$cli" validate "$destination" 2>&1) ||
  fail "validate failed: ${validate_result:-no output}"
jq -e '.success == true and .result.valid == true and .result.osType == "linux"' \
  <<<"$validate_result" >/dev/null || fail "installed machine did not validate: $validate_result"
[[ -f $destination/Disk.img && -f $destination/config.json && -f $destination/NVRAM && \
   -f $destination/MachineIdentifier && -f $destination/state.json ]] ||
  fail "installed bundle is incomplete"
state_image_path=$(jq -r '.imagePath // empty' "$destination/state.json")
[[ $state_image_path == file://* && $state_image_path == *"/Preinstalled%20Smoke.riftvm/Disk.img" ]] ||
  fail "installed state does not reference the committed disk image: $state_image_path"
[[ $state_image_path != *".install-"* ]] ||
  fail "installed state still references the staging directory"

start_result=$("$cli" start "$destination" --timeout "$timeout" 2>&1) ||
  fail "start failed: ${start_result:-no output}"
jq -e '.success == true and (.result.phase == "running" or .result.phase == "paused")' \
  <<<"$start_result" >/dev/null || fail "installed machine did not start: $start_result"
started=1
status_result=$("$cli" status "$destination" 2>&1) ||
  fail "status failed: ${status_result:-no output}"
jq -e '.success == true and (.result.phase == "running" or .result.phase == "paused")' \
  <<<"$status_result" >/dev/null || fail "installed machine did not remain active: $status_result"
stop_result=$("$cli" stop "$destination" --timeout "$timeout" 2>&1) ||
  fail "stop failed: ${stop_result:-no output}"
jq -e '.success == true and .result.phase == "stopped"' <<<"$stop_result" >/dev/null ||
  fail "installed machine did not stop cleanly: $stop_result"
started=0

echo "Verified preinstalled-image manifest, import, validation, boot, status, and clean stop with $app_path."
