#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unit="$project_root/GuestResources/Omarchy/systemd/mnt-riftvm\x2dshared.mount"
session_unit="$project_root/GuestResources/Omarchy/systemd/rift-session-agent.service"

test -f "$unit"
grep -qx 'What=riftvm_shared' "$unit"
grep -qx 'Where=/mnt/riftvm-shared' "$unit"
grep -qx 'Type=virtiofs' "$unit"
grep -qx 'Options=rw,nosuid,nodev' "$unit"
grep -qx 'WantedBy=multi-user.target' "$unit"

test -f "$session_unit"
grep -qx 'ExecStart=/usr/local/sbin/rift-agent --session' "$session_unit"
grep -qx 'PartOf=graphical-session.target' "$session_unit"
grep -qx 'WantedBy=graphical-session.target' "$session_unit"
grep -qx 'NoNewPrivileges=true' "$session_unit"
grep -qx 'ProtectSystem=strict' "$session_unit"
grep -qx 'ReadWritePaths=/run/rift-agent/sessions /mnt/riftvm-shared' "$session_unit"

if find "$project_root/GuestResources/Omarchy" -type l | grep -q .; then
    echo "Guest Overlay must not contain symbolic links" >&2
    exit 1
fi
