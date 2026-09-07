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
app_pid=""
app_identity=""
pid_file="$fixture_root/app.pid"
executable="$app_path/Contents/MacOS/RiftVM"

capture_app() {
  [[ -z "$app_pid" ]] || return 0
  local candidate command
  candidate=""
  if [[ -f "$pid_file" && ! -L "$pid_file" ]]; then
    candidate="$(tr -d '\r\n' <"$pid_file")"
  else
    # A startup alert can precede the App's PID report. Inspect only processes
    # with this executable and this launch's unique result path. Never log env.
    candidate="$(python3 - "$executable" "$result_file" <<'PYIDENTIFY'
import subprocess, sys
executable, result = sys.argv[1:]
rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
found = []
for row in rows.splitlines():
    fields = row.strip().split(None, 1)
    if len(fields) != 2 or fields[1] != executable:
        continue
    info = subprocess.run(['ps', 'eww', '-p', fields[0], '-o', 'command='], capture_output=True, text=True).stdout
    if ('RIFTVM_RELEASE_SMOKE_RESULT=' + result) in info.split():
        found.append(fields[0])
if len(found) == 1:
    print(found[0])
PYIDENTIFY
)"
  fi
  [[ "$candidate" =~ ^[1-9][0-9]*$ ]] || return 0
  command="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
  [[ "$command" == "$executable" ]] || return 0
  app_pid="$candidate"
  app_identity="$(ps -p "$app_pid" -o lstart= -o command= 2>/dev/null || true)"
}
app_is_alive() {
  [[ -n "$app_pid" && -n "$app_identity" ]] &&
    [[ "$(ps -p "$app_pid" -o lstart= -o command= 2>/dev/null || true)" == "$app_identity" ]]
}
cleanup() {
  local status=$?
  trap - EXIT
  capture_app
  if app_is_alive; then
    # This PID belongs to this temporary acceptance launch, not another workspace.
    if (( status != 0 )); then
      sample "$app_pid" 1 1 -file "$fixture_root/timeout-sample.txt" >/dev/null 2>&1 || true
    fi
    kill -TERM "$app_pid" 2>/dev/null || true
    for ((attempt=0; attempt<50; attempt++)); do
      app_is_alive || break
      sleep 0.1
    done
    if app_is_alive; then
      echo "Stopping unresponsive disposable acceptance process $app_pid" >&2
      kill -KILL "$app_pid" 2>/dev/null || true
    fi
  fi
  if [[ -n "$open_pid" ]] && kill -0 "$open_pid" 2>/dev/null; then
    kill "$open_pid" 2>/dev/null || true
    wait "$open_pid" 2>/dev/null || true
  fi
  if (( status != 0 )) || [[ "${RIFTVM_KEEP_SMOKE_ARTIFACTS:-0}" == "1" ]]; then
    echo "Retained machine-state fixture and diagnostics: $fixture_root" >&2
    echo "Retained launch log: $launch_log" >&2
  else
    rm -rf "$fixture_root"
    rm -f "$launch_log"
  fi
  exit "$status"
}
trap cleanup EXIT

clone_readonly_fixture "$vm_path" "$fixture"
rm -f "$fixture/MachineState.vzvmsave"

run_action() {
  local expected="$1"
  local save_state="$2"
  local pause_before_save="${3:-0}"
  app_pid=""
  app_identity=""
  rm -f "$result_file" "$pid_file"
  echo "Testing $expected (pause-before-save=$pause_before_save)"
  open -n -g -W --stdout "$launch_log" --stderr "$launch_log" \
    --env "RIFTVM_DATA_ROOT=$fixture_root/Library" \
    --env "RIFTVM_RELEASE_SMOKE_VM=$fixture" \
    --env "RIFTVM_RELEASE_SMOKE_RESULT=$result_file" \
    --env "RIFTVM_RELEASE_SMOKE_PID=$pid_file" \
    --env "RIFTVM_RELEASE_REQUIRE_MACHINE_STATE_SUPPORT=1" \
    --env "RIFTVM_RELEASE_SAVE_MACHINE_STATE=$save_state" \
    --env "RIFTVM_RELEASE_PAUSE_BEFORE_SAVE=$pause_before_save" \
    "$app_path" &
  open_pid=$!

  for ((second = 1; second <= timeout; second++)); do
    sleep 1
    capture_app
    if [[ -f "$result_file" ]]; then
      result="$(tr -d '\r\n' <"$result_file")"
      if [[ "$result" == "$expected" ]]; then
        if ! kill -0 "$open_pid" 2>/dev/null; then
          wait "$open_pid" || fail "application reported success but exited unsuccessfully"
          app_is_alive && fail "application reported success but remained running"
          open_pid=""
          app_pid=""
          app_identity=""
          return 0
        fi
        continue
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
