#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/riftvm-context-sync.XXXXXX)"
trap 'rm -rf "$work"' EXIT
clang -O2 -Wall -Wextra -Werror \
  "$root/Tests/CVirGLBridgeTests/ActiveContextSetTests.c" -o "$work/active-contexts"
clang -O1 -g -fsanitize=address,undefined -Wall -Wextra -Werror -Wno-unused-parameter \
  -I "$root/Experiments/VZVirtioGPUPrototype/Sources/CVirGLBridge/include" \
  "$root/Tests/CVirGLBridgeTests/ContextSyncLifecycleTests.c" -o "$work/lifecycle"
"$work/lifecycle"
"$work/active-contexts"
