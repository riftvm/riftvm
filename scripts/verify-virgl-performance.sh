#!/bin/bash

set -euo pipefail

candidate="${1:-}"

fail() {
    echo "verify-virgl-performance: $*" >&2
    exit 1
}

metric() {
    local report="$1"
    local name="$2"
    awk -F ': ' -v name="$name" '$1 == name { print substr($0, length($1) + 3); exit }' "$report"
}

number_le() {
    awk -v actual="$1" -v limit="$2" 'BEGIN { exit !(actual + 0 <= limit + 0) }'
}

number_ge() {
    awk -v actual="$1" -v limit="$2" 'BEGIN { exit !(actual + 0 >= limit + 0) }'
}

require_number() {
    local value="$1"
    local description="$2"
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "$description is not a nonnegative number: $value"
}

[[ -n "$candidate" ]] || fail "usage: $0 <custom-virgl-report>"
[[ -f "$candidate" && ! -L "$candidate" ]] || fail "missing or unsafe candidate report: $candidate"
[[ "$(metric "$candidate" Format-Version)" == "2" ]] || fail "candidate is not a version 2 capture"
[[ "$(metric "$candidate" Backend)" == "custom-virgl" ]] || fail "candidate backend must be custom-virgl"

minimum_windows="${RIFTVM_VIRGL_MIN_WINDOWS:-4}"
maximum_misses="${RIFTVM_VIRGL_MAX_DRAWABLE_MISSES:-2}"
maximum_average_present="${RIFTVM_VIRGL_MAX_AVERAGE_PRESENT_MS:-2.0}"
maximum_p95_present="${RIFTVM_VIRGL_MAX_P95_PRESENT_MS:-8.0}"
maximum_present="${RIFTVM_VIRGL_MAX_PRESENT_MS:-50.0}"
# Full frame timing includes normal display backpressure (one 60 Hz period).
maximum_average_frame="${RIFTVM_VIRGL_MAX_AVERAGE_FRAME_MS:-20.0}"
maximum_p95_frame="${RIFTVM_VIRGL_MAX_P95_FRAME_MS:-34.0}"
maximum_frame="${RIFTVM_VIRGL_MAX_FRAME_MS:-50.0}"
maximum_cpu_delta="${RIFTVM_VIRGL_MAX_CPU_DELTA_PERCENT:-25.0}"
maximum_rss_delta="${RIFTVM_VIRGL_MAX_RSS_DELTA_MIB:-512.0}"

[[ "$minimum_windows" =~ ^[0-9]+$ ]] || fail "minimum window budget must be an integer"
for budget in "$maximum_misses" "$maximum_average_present" "$maximum_p95_present" "$maximum_present" "$maximum_cpu_delta" "$maximum_rss_delta" "$maximum_average_frame" "$maximum_p95_frame" "$maximum_frame"; do
    require_number "$budget" "performance budget"
done

windows="$(metric "$candidate" VirGL-Window-Count)"
failures="$(metric "$candidate" VirGL-Presentation-Failures)"
misses="$(metric "$candidate" VirGL-Drawable-Misses)"
average_present="$(metric "$candidate" VirGL-Average-Present-Ms)"
p95_present="$(metric "$candidate" VirGL-Maximum-Window-P95-Present-Ms)"
peak_present="$(metric "$candidate" VirGL-Maximum-Present-Ms)"

[[ "$windows" =~ ^[0-9]+$ ]] || fail "candidate has no valid VirGL window count"
require_number "$failures" "presentation failure count"
require_number "$misses" "drawable miss count"
number_ge "$windows" "$minimum_windows" || fail "only $windows VirGL windows were captured; require at least $minimum_windows"
[[ "$failures" == "0" ]] || fail "$failures presentation failures were recorded"
number_le "$misses" "$maximum_misses" || fail "$misses drawable misses exceed the budget of $maximum_misses"
[[ "$average_present" != "unavailable" ]] || fail "average presentation latency is unavailable"
require_number "$average_present" "average presentation latency"
require_number "$p95_present" "maximum window P95 presentation latency"
require_number "$peak_present" "peak presentation latency"
number_le "$average_present" "$maximum_average_present" || fail "average presentation latency ${average_present}ms exceeds ${maximum_average_present}ms"
number_le "$p95_present" "$maximum_p95_present" || fail "maximum window P95 presentation latency ${p95_present}ms exceeds ${maximum_p95_present}ms"
number_le "$peak_present" "$maximum_present" || fail "peak presentation latency ${peak_present}ms exceeds ${maximum_present}ms"

# Legacy captures retain their old render timing meaning. Version 2 adds the
# drawable acquisition wait and complete CPU-side frame submission interval.
timing_version="$(metric "$candidate" VirGL-Timing-Version)"
case "$timing_version" in
    ""|1) ;;
    2)
        for family in Drawable Frame; do
            average="$(metric "$candidate" "VirGL-Average-$family-Ms")"
            p95="$(metric "$candidate" "VirGL-Maximum-Window-P95-$family-Ms")"
            peak="$(metric "$candidate" "VirGL-Maximum-$family-Ms")"
            require_number "$average" "$family average latency"
            require_number "$p95" "$family P95 latency"
            require_number "$peak" "$family peak latency"
            number_le "$average" "$maximum_average_frame" || fail "$family average latency exceeds budget"
            number_le "$p95" "$maximum_p95_frame" || fail "$family P95 latency exceeds budget"
            number_le "$peak" "$maximum_frame" || fail "$family peak latency exceeds budget"
        done
        ;;
    *) fail "capture mixes or omits extended frame timings" ;;
esac

echo "VirGL performance gate passed: windows=$windows failures=$failures misses=$misses average=${average_present}ms p95=${p95_present}ms peak=${peak_present}ms"
