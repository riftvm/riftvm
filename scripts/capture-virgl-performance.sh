#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/virgl-capture-preflight.sh
source "$script_dir/lib/virgl-capture-preflight.sh"

duration="${1:-30}"
output="${2:-/tmp/riftvm-virgl-performance-$(date +%Y%m%d-%H%M%S).txt}"
backend="${RIFTVM_VIRGL_BACKEND:-custom-virgl}"
workload="${RIFTVM_VIRGL_WORKLOAD:-unspecified}"

if ! [[ "$duration" =~ ^[0-9]+$ ]] || (( duration < 5 || duration > 600 )); then
    echo "Duration must be an integer between 5 and 600 seconds." >&2
    exit 2
fi

case "$backend" in
    custom-virgl) ;;
    *)
        echo "RIFTVM_VIRGL_BACKEND must be custom-virgl: RiftVM runs no other backend." >&2
        exit 2
        ;;
esac

if [[ "$workload" == *$'\n'* || "$workload" == *$'\r'* ]]; then
    echo "RIFTVM_VIRGL_WORKLOAD must be a single line." >&2
    exit 2
fi

discovered_pids="$(pgrep -x RiftVM || true)"
pid="$(select_virgl_capture_pid "${RIFTVM_VIRGL_PID:-}" "$discovered_pids")" || exit $?
if ! kill -0 "$pid" 2>/dev/null; then
    echo "RiftVM process $pid is no longer running." >&2
    exit 1
fi
process_name="$(ps -p "$pid" -o comm= | awk -F/ '{ print $NF }')"
if [[ "$process_name" != "RiftVM" ]]; then
    echo "Process $pid is $process_name, not RiftVM." >&2
    exit 1
fi

samples="$(mktemp /tmp/riftvm-virgl-samples.XXXXXX)"
graphics_logs="$(mktemp /tmp/riftvm-virgl-logs.XXXXXX)"
log_pid=""
cleanup() {
    if [[ -n "$log_pid" ]] && kill -0 "$log_pid" 2>/dev/null; then
        kill "$log_pid" 2>/dev/null || true
        wait "$log_pid" 2>/dev/null || true
    fi
    rm -f "$samples" "$graphics_logs"
}
trap cleanup EXIT
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

/usr/bin/log stream --style compact --level info \
    --predicate "processID == $pid AND subsystem == 'com.riftvm.app' AND (category == 'graphics' OR category == 'virtio-gpu')" \
    > "$graphics_logs" &
log_pid=$!

for (( second = 0; second < duration; second++ )); do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "RiftVM stopped before the capture completed." >&2
        exit 1
    fi
    ps -p "$pid" -o %cpu=,rss= >> "$samples"
    sleep 1
done

kill "$log_pid" 2>/dev/null || true
wait "$log_pid" 2>/dev/null || true
log_pid=""

percentile() {
    local column="$1"
    local percentile="$2"
    awk -v column="$column" '{ print $column }' "$samples" | \
        LC_ALL=C sort -n | \
        awk -v percentile="$percentile" '
            { values[NR] = $1 }
            END {
                if (NR == 0) exit 1
                slot = int((NR - 1) * percentile) + 1
                printf "%.1f", values[slot]
            }
        '
}

virgl_summary() {
    awk -f "$script_dir/lib/virgl-summary.awk" "$graphics_logs"
}

{
    echo "# RiftVM VirGL performance capture"
    echo "Format-Version: 2"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Started: $started_at"
    echo "Duration: ${duration}s"
    echo "Backend: $backend"
    echo "Workload: $workload"
    echo "PID: $pid"
    echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "Hardware: $(sysctl -n hw.model)"
    echo
    echo "# Machine-readable summary"
    awk '
        { cpu += $1; if ($1 > max_cpu) max_cpu = $1; rss += $2; if ($2 > max_rss) max_rss = $2; count++ }
        END {
            if (count == 0) exit 1
            printf "Sample-Count: %d\nHost-Average-CPU-Percent: %.1f\nHost-Peak-CPU-Percent: %.1f\nHost-Average-RSS-MiB: %.1f\nHost-Peak-RSS-MiB: %.1f\n", count, cpu / count, max_cpu, rss / count / 1024, max_rss / 1024
        }
    ' "$samples"
    echo "Host-P50-CPU-Percent: $(percentile 1 0.50)"
    echo "Host-P95-CPU-Percent: $(percentile 1 0.95)"
    echo "Host-P50-RSS-MiB: $(awk '{ print $2 / 1024 }' "$samples" | LC_ALL=C sort -n | awk '{ values[NR] = $1 } END { slot = int((NR - 1) * 0.50) + 1; printf "%.1f", values[slot] }')"
    echo "Host-P95-RSS-MiB: $(awk '{ print $2 / 1024 }' "$samples" | LC_ALL=C sort -n | awk '{ values[NR] = $1 } END { slot = int((NR - 1) * 0.95) + 1; printf "%.1f", values[slot] }')"
    virgl_summary
    echo
    echo "# Per-second samples (%CPU RSS-KiB)"
    cat "$samples"
    echo
    echo "# RiftVM graphics and virtio-gpu logs"
    cat "$graphics_logs"
} > "$output"

echo "$output"
