#!/usr/bin/env bash
#
# Fails when the Swift files under Core/VMKit (minus the ones Package.swift
# excludes on purpose) differ from what SwiftPM compiles into RiftVMCore.
#
# The RiftVMCore target has no explicit `sources:` list, so new files are picked
# up automatically. This check catches the ways that can still go wrong: a file
# added to `exclude:` by accident, a stale exclusion, or a `sources:` list
# creeping back in and silently dropping new files from `swift test`.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_name="RiftVMCore"
target_dir="RiftVM/RiftVM/Core/VMKit"

# Paths relative to $target_dir that are intentionally not part of the package.
excluded=(
    "Graphics/VMCustomVirGLGraphics.swift"
)

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

(
    cd "$repo_root/$target_dir"
    find . -type f -name '*.swift' | sed 's|^\./||'
) | LC_ALL=C sort > "$work_dir/on-disk-all"

printf '%s\n' "${excluded[@]}" | LC_ALL=C sort > "$work_dir/excluded"

while IFS= read -r path; do
    if [[ ! -f "$repo_root/$target_dir/$path" ]]; then
        echo "error: excluded file does not exist: $target_dir/$path" >&2
        exit 1
    fi
done < "$work_dir/excluded"

LC_ALL=C comm -23 "$work_dir/on-disk-all" "$work_dir/excluded" > "$work_dir/expected"

(cd "$repo_root" && swift package describe --type json) > "$work_dir/describe.json"

/usr/bin/python3 - "$work_dir/describe.json" "$target_name" > "$work_dir/actual-unsorted" <<'PY'
import json
import sys

path, target_name = sys.argv[1], sys.argv[2]
with open(path) as handle:
    text = handle.read()
# SwiftPM may print diagnostics before the JSON document.
package = json.loads(text[text.index("{"):])
targets = [t for t in package["targets"] if t["name"] == target_name]
if len(targets) != 1:
    sys.exit(f"error: expected exactly one target named {target_name}")
for source in targets[0]["sources"]:
    print(source)
PY
LC_ALL=C sort "$work_dir/actual-unsorted" > "$work_dir/actual"

if ! diff -u "$work_dir/expected" "$work_dir/actual" > "$work_dir/diff"; then
    echo "error: $target_name sources do not match the Swift files under $target_dir." >&2
    echo "       '-' lines exist on disk but are not compiled by SwiftPM;" >&2
    echo "       '+' lines are compiled by SwiftPM but were not expected." >&2
    cat "$work_dir/diff" >&2
    exit 1
fi

echo "$target_name compiles all $(wc -l < "$work_dir/actual" | tr -d ' ') expected Swift files under $target_dir."
