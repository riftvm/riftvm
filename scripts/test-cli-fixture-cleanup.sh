#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/cli-fixture-cleanup.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
cat > "$root/cli" <<'CLI'
#!/bin/bash
# Stop may fail because the VM is already stopped, or ownership is unknown.
[[ "$1" == status ]] || exit 1
case "$(basename "$2")" in
  stopped) echo '{"success":true,"result":{"phase":"stopped"}}' ;;
  running) echo '{"success":true,"result":{"phase":"running"}}' ;;
  unknown) echo '{"success":false,"error":{"code":"process_ownership_unverified"}}'; exit 1 ;;
  corrupt) echo 'invalid JSON' ;;
  failed) echo '{"success":false,"result":{"phase":"stopped"}}' ;;
esac
CLI
chmod +x "$root/cli"
for state in running unknown corrupt failed; do
  directory="$root/$state-fixtures"
  mkdir -p "$directory/stopped" "$directory/$state"
  echo retained > "$directory/$state/disk"
  if cleanup_cli_fixtures "$root/cli" "$directory" "$directory/stopped" "$directory/$state"; then
    echo "Unsafe cleanup accepted $state" >&2; exit 1
  fi
  [[ "$(cat "$directory/$state/disk")" == retained && -d "$directory/stopped" ]]
done
directory="$root/stopped-fixtures"
mkdir -p "$directory/stopped"
cleanup_cli_fixtures "$root/cli" "$directory" "$directory/stopped"
[[ ! -e "$directory" ]]
echo 'Verified cleanup preserves live, unverified, malformed and failed runtime states.'
