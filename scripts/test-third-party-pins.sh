#!/bin/bash

set -euo pipefail

# THIRD_PARTY_NOTICES.md repeats the commits that scripts/virgl-runtime-pins.sh
# pins. The notice ships inside every release, so a pin that moves without the
# notice following would publish a wrong source reference. Fail when they differ.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$project_root/scripts/lib/common.sh"
# shellcheck source=scripts/virgl-runtime-pins.sh
source "$project_root/scripts/virgl-runtime-pins.sh"

notices="${1:-$project_root/THIRD_PARTY_NOTICES.md}"
[[ -f "$notices" ]] || fail "notices file not found: $notices"

# check_component <table label> <upstream commit> <recipe repository> <recipe commit>
check_component() {
  local label="$1" upstream="$2" recipe_repository="$3" recipe="$4"
  local row
  row="$(grep -F "| $label " "$notices" || true)"
  [[ -n "$row" ]] || fail "THIRD_PARTY_NOTICES.md has no table row for $label"
  [[ "$(printf '%s\n' "$row" | wc -l | tr -d ' ')" == 1 ]] || \
    fail "THIRD_PARTY_NOTICES.md has more than one table row for $label"
  [[ "$upstream" =~ ^[0-9a-f]{40}$ ]] || fail "$label upstream pin is not a full commit: $upstream"
  [[ "$recipe" =~ ^[0-9a-f]{40}$ ]] || fail "$label build recipe pin is not a full commit: $recipe"
  [[ "$row" == *"| \`$upstream\` |"* ]] || \
    fail "$label runtime version in THIRD_PARTY_NOTICES.md does not match virgl-runtime-pins.sh ($upstream)"
  [[ "$row" == *"| \`$recipe_repository@$recipe\` |"* ]] || \
    fail "$label build recipe in THIRD_PARTY_NOTICES.md does not match virgl-runtime-pins.sh ($recipe_repository@$recipe)"
}

check_component "virglrenderer" \
  "$RIFTVM_VIRGL_UPSTREAM_COMMIT" startergo/homebrew-virglrenderer "$RIFTVM_VIRGL_BUILD_RECIPE_COMMIT"
check_component "libepoxy" \
  "$RIFTVM_EPOXY_UPSTREAM_COMMIT" startergo/homebrew-libepoxy "$RIFTVM_EPOXY_BUILD_RECIPE_COMMIT"
check_component "ANGLE" \
  "$RIFTVM_ANGLE_UPSTREAM_COMMIT" startergo/homebrew-angle "$RIFTVM_ANGLE_BUILD_RECIPE_COMMIT"

# Every full commit hash the notice mentions must be one of the pins, so a stale
# hash cannot linger in the prose around the table either.
while IFS= read -r commit; do
  case "$commit" in
    "$RIFTVM_VIRGL_UPSTREAM_COMMIT"|"$RIFTVM_VIRGL_BUILD_RECIPE_COMMIT"|\
    "$RIFTVM_EPOXY_UPSTREAM_COMMIT"|"$RIFTVM_EPOXY_BUILD_RECIPE_COMMIT"|\
    "$RIFTVM_ANGLE_UPSTREAM_COMMIT"|"$RIFTVM_ANGLE_BUILD_RECIPE_COMMIT") ;;
    *) fail "THIRD_PARTY_NOTICES.md mentions $commit, which virgl-runtime-pins.sh does not pin" ;;
  esac
done < <(grep -oE '[0-9a-f]{40}' "$notices" | sort -u)

echo "THIRD_PARTY_NOTICES.md matches scripts/virgl-runtime-pins.sh."
