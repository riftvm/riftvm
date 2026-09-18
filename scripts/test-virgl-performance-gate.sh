#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
verifier="$project_root/scripts/verify-virgl-performance.sh"
temporary_directory="$(mktemp -d /tmp/riftvm-virgl-gate-tests.XXXXXX)"
trap 'rm -rf "$temporary_directory"' EXIT

write_report() {
    local path="$1"
    local backend="$2"
    local failures="$3"
    local misses="$4"
    local average_present="$5"
    local p95_present="$6"
    local peak_present="$7"
    local cpu="$8"
    local rss="$9"
    printf '%s\n' \
        'Format-Version: 2' \
        'Duration: 30s' \
        "Backend: $backend" \
        'Workload: hyprland-idle-1920x1080' \
        'macOS: 27.0 (26A123)' \
        'Hardware: Mac16,1' \
        "Host-Average-CPU-Percent: $cpu" \
        "Host-Average-RSS-MiB: $rss" \
        'VirGL-Window-Count: 5' \
        "VirGL-Drawable-Misses: $misses" \
        "VirGL-Presentation-Failures: $failures" \
        "VirGL-Average-Present-Ms: $average_present" \
        "VirGL-Maximum-Window-P95-Present-Ms: $p95_present" \
        "VirGL-Maximum-Present-Ms: $peak_present" > "$path"
}

candidate="$temporary_directory/candidate.txt"
write_report "$candidate" custom-virgl 0 1 0.7 2.2 25.0 35 900
"$verifier" "$candidate" >/dev/null

write_report "$candidate" custom-virgl 1 1 0.7 2.2 25.0 35 900
if "$verifier" "$candidate" >/dev/null 2>&1; then
    echo "A report with presentation failures passed unexpectedly." >&2
    exit 1
fi

write_report "$candidate" custom-virgl 0 1 0.7 2.2 50.1 35 900
if "$verifier" "$candidate" >/dev/null 2>&1; then
    echo "A report over the peak presentation budget passed unexpectedly." >&2
    exit 1
fi

write_report "$candidate" custom-virgl 0 1 0.7 8.1 25.0 35 900
if "$verifier" "$candidate" >/dev/null 2>&1; then
    echo "A report over the P95 presentation budget passed unexpectedly." >&2
    exit 1
fi

write_report "$candidate" custom-virgl 0 9 0.7 2.2 25.0 35 900
if "$verifier" "$candidate" >/dev/null 2>&1; then
    echo "A report over the drawable miss budget passed unexpectedly." >&2
    exit 1
fi

write_report "$temporary_directory/other-backend.txt" apple-virtio 0 0 unavailable unavailable unavailable 20 700
if "$verifier" "$temporary_directory/other-backend.txt" >/dev/null 2>&1; then
    echo "A report from a backend RiftVM no longer runs passed unexpectedly." >&2
    exit 1
fi

echo "VirGL performance gate tests passed."

# Extended timing must expose a drawable stall even when render timing is low.
write_report "$candidate" custom-virgl 0 0 0.5 1.0 2.0 10 200
cat >> "$candidate" <<'TIMING'
VirGL-Timing-Version: 2
VirGL-Average-Drawable-Ms: 0.1
VirGL-Maximum-Window-P95-Drawable-Ms: 0.2
VirGL-Maximum-Drawable-Ms: 1.0
VirGL-Average-Frame-Ms: 0.6
VirGL-Maximum-Window-P95-Frame-Ms: 1.2
VirGL-Maximum-Frame-Ms: 3.0
TIMING
# A frame can include a display interval without the renderer itself stalling.
sed -i '' 's/VirGL-Average-Frame-Ms: 0.6/VirGL-Average-Frame-Ms: 15.0/; s/VirGL-Maximum-Window-P95-Frame-Ms: 1.2/VirGL-Maximum-Window-P95-Frame-Ms: 17.0/; s/VirGL-Maximum-Frame-Ms: 3.0/VirGL-Maximum-Frame-Ms: 18.0/' "$candidate"
"$verifier" "$candidate" >/dev/null
sed -i '' 's/VirGL-Maximum-Drawable-Ms: 1.0/VirGL-Maximum-Drawable-Ms: 60.0/' "$candidate"
if "$verifier" "$candidate" >/dev/null 2>&1; then
    echo 'Drawable stall passed unexpectedly' >&2; exit 1
fi
sed -i '' 's/VirGL-Timing-Version: 2/VirGL-Timing-Version: incomplete/' "$candidate"
if "$verifier" "$candidate" >/dev/null 2>&1; then
    echo 'Mixed timing versions passed unexpectedly' >&2; exit 1
fi

raw="$temporary_directory/raw.txt"
printf '%s\n' 'VirGL performance: fps=60 requested=300 presented=300 drawableMisses=0 failures=0 avgPresentMs=0.5 p95PresentMs=1 maxPresentMs=2 timingVersion=2 avgDrawableMs=0.1 p95DrawableMs=0.2 maxDrawableMs=1 avgFrameMs=0.6 p95FrameMs=1.2 maxFrameMs=3' > "$raw"
awk -f "$project_root/scripts/lib/virgl-summary.awk" "$raw" > "$temporary_directory/summary.txt"
grep -qx 'VirGL-Timing-Version: 2' "$temporary_directory/summary.txt"
grep -qx 'VirGL-Average-Frame-Ms: 0.60' "$temporary_directory/summary.txt"
printf '%s\n' 'VirGL performance: fps=60 avgPresentMs=0.5 p95PresentMs=1 maxPresentMs=2' >> "$raw"
awk -f "$project_root/scripts/lib/virgl-summary.awk" "$raw" > "$temporary_directory/summary.txt"
grep -qx 'VirGL-Timing-Version: incomplete' "$temporary_directory/summary.txt"
awk -f "$project_root/scripts/lib/virgl-summary.awk" /dev/null > "$temporary_directory/summary.txt"
grep -qx 'VirGL-Average-Frame-Ms: unavailable' "$temporary_directory/summary.txt"
echo 'Extended drawable/frame timing tests passed.'
