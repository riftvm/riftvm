#!/bin/bash

# Only delete disposable test disks after the CLI positively confirms that
# every associated runtime is stopped. Preserve evidence on ambiguous ownership.
cleanup_cli_fixtures() {
  local cli="$1" directory="$2" vm status_json
  shift 2
  local verified=1
  for vm in "$@"; do
    [[ -d "$vm" ]] || continue
    "$cli" stop "$vm" --timeout 25 >/dev/null 2>&1 || true
    if ! status_json="$("$cli" status "$vm")" ||
       ! ruby -rjson -e '
         response = JSON.parse(STDIN.read)
         exit(response["success"] == true && response.dig("result", "phase") == "stopped" ? 0 : 1)
       ' <<<"$status_json" 2>/dev/null; then
      echo "Cannot verify stopped runtime; preserving test fixtures: $vm" >&2
      verified=0
    fi
  done
  [[ "$verified" == 1 ]] || return 1
  rm -rf "$directory"
}
