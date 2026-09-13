#!/bin/bash
# Run in a disposable Guest terminal after installing both candidate Guest
# components. The host observer samples phase.txt; no mouse movement is needed.
set -euo pipefail
out=${1:-/mnt/riftvm-shared/vfr-final}
mkdir -p "$out"
hyprctl -j getoption debug:vfr > "$out/vfr-at-start.json"
initial=$(jq -r .bool "$out/vfr-at-start.json")
restore() {
  hyprctl eval "hl.config({ debug = { vfr = $initial } })" >/dev/null || true
  printf '\033[?25h'
}
trap restore EXIT
printf '\033[?25l'
for phase in continuous-1 demand-1; do
  enabled=true
  [[ $phase != continuous-* ]] || enabled=false
  hyprctl eval "hl.config({ debug = { vfr = $enabled } })" >/dev/null
  printf '\033[2J\033[H%s: STATIC DESKTOP\n' "$phase"
  printf 'settling\n' > "$out/phase.txt"
  sleep 10
  hyprctl -j getoption debug:vfr > "$out/$phase-before.json"
  printf '%s\n' "$phase" > "$out/phase.txt"
  sleep 15
  hyprctl -j getoption debug:vfr > "$out/$phase-after.json"
done
printf 'done\n' > "$out/phase.txt"
printf '\033[2J\033[H\033[44m FINAL BLUE FRAME WITHOUT POINTER INPUT \033[0m\n'
