#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output=""
status=0

output="$("$project_root/scripts/build-release.sh" 2>&1)" || status=$?

if [[ "$status" -ne 64 ]]; then
  echo "expected obsolete signing variable to fail with status 64, got $status" >&2
  exit 1
fi
if [[ "$output" != *"usage:"* ]]; then
  echo "missing version did not produce actionable usage guidance" >&2
  exit 1
fi
if [[ -e /tmp/riftvm-legacy-signing-test ]]; then
  echo "signing preflight mutated the requested output directory" >&2
  exit 1
fi

echo "Verified release argument preflight."
