#!/bin/bash

set -euo pipefail

app_path="${1:-}"
expected_version="${2:-}"
expected_revision="${3:-${RIFTVM_EXPECTED_SOURCE_REVISION:-}}"
launch_timeout="${RIFTVM_LAUNCH_TIMEOUT:-10}"

fail() {
  echo "verify-release-app: $*" >&2
  exit 1
}

[[ -n "$app_path" ]] || fail "usage: $0 <RiftVM.app> [expected-version]"
[[ -d "$app_path" ]] || fail "application not found: $app_path"
"$(dirname "$0")/verify-production-test-isolation.sh" "$app_path"
[[ "$launch_timeout" =~ ^[1-9][0-9]*$ ]] || fail "RIFTVM_LAUNCH_TIMEOUT must be a positive integer"

for command in codesign defaults open osascript pgrep plutil ps spctl; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

executable="$app_path/Contents/MacOS/RiftVM"
[[ -x "$executable" ]] || fail "application executable not found: $executable"
cli="$app_path/Contents/Helpers/riftvm"
[[ -x "$cli" ]] || fail "CLI executable not found: $cli"

# Launching a quarantined copy exercises Gatekeeper's first-launch path, which
# consults the host security daemon before the process reaches main(). On a host
# whose daemon is unresponsive the probe blocks forever with no output, which
# reads as a release failure when it is an environment failure: `spctl` below
# still has to accept the bundle either way. Bound the probe so that host fails
# visibly instead of hanging.
doctor_timeout="${RIFTVM_DOCTOR_TIMEOUT:-60}"
[[ "$doctor_timeout" =~ ^[1-9][0-9]*$ ]] || fail "RIFTVM_DOCTOR_TIMEOUT must be a positive integer"
doctor_out="$(mktemp "${TMPDIR:-/tmp}/riftvm-doctor.XXXXXX")"
doctor_err="$(mktemp "${TMPDIR:-/tmp}/riftvm-doctor-err.XXXXXX")"
doctor_status=0
timeout "$doctor_timeout" "$cli" doctor >"$doctor_out" 2>"$doctor_err" || doctor_status=$?
if (( doctor_status != 0 )); then
  cat "$doctor_err" >&2
  rm -f "$doctor_out" "$doctor_err"
  fail "the CLI probe failed with status $doctor_status after ${doctor_timeout}s"
fi
ruby -rjson -e 'JSON.parse(STDIN.read)' <"$doctor_out"
rm -f "$doctor_out" "$doctor_err"

codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

"$(dirname "$0")/verify-release-metadata.sh" \
  "$app_path" "$expected_version" "$expected_revision" clean

launch_log="$(mktemp "${TMPDIR:-/tmp}/riftvm-launch.XXXXXX")"
ready_dir="$(mktemp -d "${TMPDIR:-/tmp}/riftvm-gui-ready.XXXXXX")"
ready_file="$ready_dir/ready.json"
app_pid=""
cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -f "$launch_log" "$ready_file"
  rmdir "$ready_dir" 2>/dev/null || true
}
trap cleanup EXIT

"$(dirname "$0")/verify-production-entitlements.sh" "$app_path"

# Launch through Launch Services so macOS applies the same sandbox extensions
# as a normal Finder/Homebrew launch. Track the newly created process even when
# it never reaches the readiness marker, so the cleanup trap can still stop it.
existing_pids="$(pgrep -x RiftVM 2>/dev/null | tr '\n' ' ' || true)"
[[ -z "${existing_pids// /}" ]] || \
  fail "another RiftVM instance is running; quit it before release verification"
open -n --stdout "$launch_log" --stderr "$launch_log" \
  --env "RIFTVM_GUI_READY_FILE=$ready_file" "$app_path"

find_new_app_pid() {
  local pid
  for pid in $(pgrep -x RiftVM 2>/dev/null || true); do
    if [[ "$existing_pids" != *" $pid "* ]]; then
      printf '%s\n' "$pid"
      return
    fi
  done
}

for _ in {1..50}; do
  app_pid="$(find_new_app_pid)"
  [[ -n "$app_pid" ]] && break
  sleep 0.1
done
[[ -n "$app_pid" ]] || { cat "$launch_log" >&2; fail "Launch Services did not start RiftVM"; }

# SwiftUI can restore the persisted state where every window was closed.
# A normal second click on the app sends reopen/activate, so exercise that
# public lifecycle path before requiring a visible Control Center window.
osascript \
  -e 'tell application id "com.riftvm.app" to reopen' \
  -e 'tell application id "com.riftvm.app" to activate'

for ((second = 1; second <= launch_timeout; second++)); do
  for _ in {1..10}; do
    if [[ -z "$app_pid" ]]; then app_pid="$(find_new_app_pid)"; fi
    if [[ -f "$ready_file" ]]; then break 2; fi
    sleep 0.1
  done
done

[[ -f "$ready_file" ]] || { cat "$launch_log" >&2; fail "SwiftUI did not report a visible main window"; }
ruby -rjson -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong readiness schema" unless value["schemaVersion"] == 1
  abort "main event loop did not respond" unless value["eventLoopResponsive"] == true
  abort "window is not visible" unless value["windowVisible"] == true
  abort "window is too small" unless value["windowWidth"] >= 800 && value["windowHeight"] >= 600
  abort "wrong bundle" unless value["bundleIdentifier"] == "com.riftvm.app"
' "$ready_file"

app_pid="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("pid")' "$ready_file")"
kill -0 "$app_pid" 2>/dev/null || { cat "$launch_log" >&2; fail "application exited after reporting GUI readiness"; }

process_command="$(ps -p "$app_pid" -o command=)"
[[ "$process_command" == *"/Contents/MacOS/RiftVM"* ]] || \
  fail "unexpected process after launch: $process_command"

echo "Verified RiftVM release app: signature, Gatekeeper, version, entitlement allowlist, and a visible SwiftUI main window."
