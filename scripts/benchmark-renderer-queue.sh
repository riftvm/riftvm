#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
base="${1:-HEAD}"
work="$(mktemp -d /tmp/riftvm-renderer-queue.XXXXXX)"
trap 'rm -rf "$work"' EXIT
source_path=Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/RendererExecutor.swift
git -C "$root" show "$base:$source_path" > "$work/RendererExecutor.swift"
export CLANG_MODULE_CACHE_PATH="$work/ModuleCache"
swiftc -O -swift-version 5 "$work/RendererExecutor.swift" \
  "$root/Tests/Performance/RendererQueueBenchmark.swift" -o "$work/before"
swiftc -O -swift-version 5 "$root/$source_path" \
  "$root/Tests/Performance/RendererQueueBenchmark.swift" -o "$work/after"
"$work/before" baseline
"$work/after" candidate
