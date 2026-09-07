#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/readonly-fixture-guard.sh
source "$project_root/scripts/lib/readonly-fixture-guard.sh"

test_root="$(mktemp -d /tmp/riftvm-readonly-fixture-test.XXXXXX)"
fixture="$test_root/Original.riftvm"
clone="$test_root/Clone.riftvm"
mkdir "$fixture"
cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

mkdir "$fixture/nested"
printf 'configuration\n' >"$fixture/config.json"
ln -s config.json "$fixture/config-link"

printf '{"schemaVersion":1,"profile":"linux","id":"F4696BAE-A92B-4115-BEEA-C89F21C4EEB8"}' >"$fixture/Workspace.json"
fingerprint="$(fixture_metadata_fingerprint "$fixture")"
assert_fixture_unchanged "$fixture" "$fingerprint"

clone_readonly_fixture "$fixture" "$clone"
renew_fixture_workspace_identity "$clone"
ruby -rjson -e '
  original, copy = ARGV.map { |p| JSON.parse(File.read(File.join(p, "Workspace.json"))) }
  abort "Clone retained source identity" if original["id"] == copy["id"]
  abort "Clone altered other identity fields" unless original.reject { |k, _| k == "id" } == copy.reject { |k, _| k == "id" }
' "$fixture" "$clone"
printf 'clone only\n' >>"$clone/config.json"
assert_fixture_unchanged "$fixture" "$fingerprint"
[[ "$(cat "$fixture/config.json")" == "configuration" ]] || {
  echo "writing the clone changed the read-only fixture" >&2
  exit 1
}
if clone_readonly_fixture "$fixture" "$clone" >/dev/null 2>&1; then
  echo "fixture clone guard accepted an existing destination" >&2
  exit 1
fi
if clone_readonly_fixture "$fixture" "$fixture/nested/Clone.riftvm" >/dev/null 2>&1; then
  echo "fixture clone guard accepted a destination inside the source" >&2
  exit 1
fi

chmod 600 "$fixture/config.json"
if assert_fixture_unchanged "$fixture" "$fingerprint" >/dev/null 2>&1; then
  echo "fixture guard ignored a permission change" >&2
  exit 1
fi

fingerprint="$(fixture_metadata_fingerprint "$fixture")"
printf 'changed\n' >>"$fixture/config.json"
if assert_fixture_unchanged "$fixture" "$fingerprint" >/dev/null 2>&1; then
  echo "fixture guard ignored a content write" >&2
  exit 1
fi

fingerprint="$(fixture_metadata_fingerprint "$fixture")"
touch "$fixture/new-file"
if assert_fixture_unchanged "$fixture" "$fingerprint" >/dev/null 2>&1; then
  echo "fixture guard ignored a new file" >&2
  exit 1
fi

echo "Verified read-only fixture mutation detection."
