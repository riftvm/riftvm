#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/readonly-fixture-guard.sh
source "$project_root/scripts/lib/readonly-fixture-guard.sh"
app_path="${1:-}"
vm_path="${2:-}"
timeout="${RIFTVM_VM_SMOKE_TIMEOUT:-90}"

fail() {
  echo "verify-release-machine-state-support: $*" >&2
  exit 1
}

[[ -d "$app_path" && -d "$vm_path" ]] || fail "usage: $0 <RiftVM.app> <macos-vm>"
[[ -f "$vm_path/config.json" ]] || fail "fixture has no config.json: $vm_path"
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "RIFTVM_VM_SMOKE_TIMEOUT must be a positive integer"

fixture_parent="${TMPDIR:-/tmp}"
fixture_root="$(mktemp -d "$fixture_parent/.riftvm-machine-state-fixture.XXXXXX")"
fixture="$fixture_root/Machine-State.riftvm"
result_file="$fixture_root/result.txt"
launch_log="$(mktemp "${TMPDIR:-/tmp}/riftvm-machine-state-launch.XXXXXX")"
open_pid=""
cleanup() {
  if [[ -n "$open_pid" ]] && kill -0 "$open_pid" 2>/dev/null; then
    kill "$open_pid" 2>/dev/null || true
    wait "$open_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture_root"
  rm -f "$launch_log"
}
trap cleanup EXIT

clone_readonly_fixture "$vm_path" "$fixture"
rm -f "$fixture/MachineState.vzvmsave"

run_action() {
  local expected="$1"
  local save_state="$2"
  local pause_before_save="${3:-0}"
  rm -f "$result_file"
  open -n -g -W --stdout "$launch_log" --stderr "$launch_log" \
    --env "RIFTVM_RELEASE_SMOKE_VM=$fixture" \
    --env "RIFTVM_RELEASE_SMOKE_RESULT=$result_file" \
    --env "RIFTVM_RELEASE_REQUIRE_MACHINE_STATE_SUPPORT=1" \
    --env "RIFTVM_RELEASE_SAVE_MACHINE_STATE=$save_state" \
    --env "RIFTVM_RELEASE_PAUSE_BEFORE_SAVE=$pause_before_save" \
    "$app_path" &
  open_pid=$!

  for ((second = 1; second <= timeout; second++)); do
    sleep 1
    if [[ -f "$result_file" ]]; then
      result="$(tr -d '\r\n' <"$result_file")"
      if [[ "$result" == "$expected" ]]; then
        wait "$open_pid" || true
        open_pid=""
        return 0
      fi
      cat "$launch_log" >&2
      fail "$result"
    fi
    if ! kill -0 "$open_pid" 2>/dev/null; then
      wait "$open_pid" || exit_code=$?
      cat "$launch_log" >&2
      fail "application exited before reporting a result with status ${exit_code:-0}"
    fi
  done

  cat "$launch_log" >&2
  fail "timed out after ${timeout}s waiting for $expected"
}

run_action machine-state-saved 1
[[ -f "$fixture/MachineState.vzvmsave" ]] || fail "save action did not create MachineState.vzvmsave"
run_action restored-and-stopped 0
[[ ! -e "$fixture/MachineState.vzvmsave" ]] || fail "restored machine state was not consumed"

run_action machine-state-saved 1 1
[[ -f "$fixture/MachineState.vzvmsave" ]] || fail "paused save did not create MachineState.vzvmsave"
run_action restored-and-stopped 0
[[ ! -e "$fixture/MachineState.vzvmsave" ]] || fail "paused saved state was not consumed"

echo "Verified macOS VM save and cross-process restore from running and paused states."
