#!/bin/bash

# Small helpers shared by the test-*.sh and verify-*.sh scripts that CI runs.
# Source this file; it defines functions only and changes no shell options.
#
# The release scripts (release-*.sh, publish-*.sh, build-release.sh,
# sign-*.sh) deliberately do not use it: each of them stays readable and
# auditable on its own.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "common.sh must be sourced" >&2
  exit 64
fi

# The name printed in front of every failure. Defaults to the calling script's
# file name without ".sh"; set RIFTVM_SCRIPT_NAME before calling to override.
riftvm_script_name() {
  local name=${RIFTVM_SCRIPT_NAME:-}
  if [[ -z $name ]]; then
    name=$(basename -- "$0")
    name=${name%.sh}
  fi
  printf '%s\n' "$name"
}

# fail <message...>: print "<script>: <message>" on stderr and exit 1.
fail() {
  printf '%s: %s\n' "$(riftvm_script_name)" "$*" >&2
  exit 1
}

# require_command <command...>: fail unless every command is on PATH.
require_command() {
  local required
  for required in "$@"; do
    command -v "$required" >/dev/null 2>&1 || fail "required command not found: $required"
  done
}

# riftvm_sha256 <file>: print the lowercase SHA-256 of a file.
riftvm_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# riftvm_project_root: print the repository root, resolved from this file.
riftvm_project_root() {
  (cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
}

# riftvm_temp_root: print the directory temporary files belong in. CI sets
# RUNNER_TEMP, macOS sets TMPDIR, and /tmp is the last resort.
riftvm_temp_root() {
  local root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
  while [[ ${#root} -gt 1 && $root == */ ]]; do
    root=${root%/}
  done
  printf '%s\n' "$root"
}

# riftvm_mktemp_dir <prefix>: create a private temporary directory named
# <prefix>.XXXXXX under riftvm_temp_root and print its path.
riftvm_mktemp_dir() {
  mktemp -d "$(riftvm_temp_root)/$1.XXXXXX"
}
