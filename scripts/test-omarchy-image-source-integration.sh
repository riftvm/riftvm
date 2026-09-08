#!/bin/bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${RUNNER_TEMP:-/tmp}/riftvm-omarchy-image-source.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
profile="$fixture/profiles/aarch64-virt"
agent_ref=$(git -C "$project_root" rev-parse HEAD)
mkdir -p "$fixture/bin" "$profile/overlay/etc/systemd/system" "$profile/overlay/etc/systemd/user"
cp "$project_root/RiftVM/GuestOverlay/systemd/mnt-riftvm\x2dshared.mount" \
  "$profile/overlay/etc/systemd/system/mnt-riftvm\x2dshared.mount"
cp "$project_root/RiftVM/GuestOverlay/systemd/rift-session-agent.service" \
  "$profile/overlay/etc/systemd/user/rift-session-agent.service"
printf '%s\n' wl-clipboard >"$profile/runtime-packages"
printf 'RIFTVM_GUEST_AGENT_REF=%s\n' "$agent_ref" >"$fixture/sources.env"
cat >"$fixture/bin/build-image" <<'EOF'
target_chroot systemctl enable 'mnt-riftvm\x2dshared.mount'
install -d -m755 "$MOUNT_DIR/mnt/riftvm-shared"
target_chroot systemctl --global enable rift-session-agent.service
required_paths=(
  'etc/systemd/system/mnt-riftvm\x2dshared.mount'
  etc/systemd/user/rift-session-agent.service
  'etc/systemd/system/multi-user.target.wants/mnt-riftvm\x2dshared.mount'
  mnt/riftvm-shared
  etc/systemd/user/graphical-session.target.wants/rift-session-agent.service
)
EOF
cp "$fixture/bin/build-image" "$fixture/build-image.valid"

verify="$project_root/scripts/verify-omarchy-image-source-integration.sh"
"$verify" "$fixture" >/dev/null
printf '\nExecStart=/bin/false\n' >>"$profile/overlay/etc/systemd/user/rift-session-agent.service"
if "$verify" "$fixture" >/dev/null 2>&1; then
  echo "verifier accepted a modified Session Agent unit" >&2
  exit 1
fi
cp "$project_root/RiftVM/GuestOverlay/systemd/rift-session-agent.service" \
  "$profile/overlay/etc/systemd/user/rift-session-agent.service"
sed -i '' '/wl-clipboard/d' "$profile/runtime-packages"
if "$verify" "$fixture" >/dev/null 2>&1; then
  echo "verifier accepted an image without wl-clipboard" >&2
  exit 1
fi
printf '%s\n' wl-clipboard >"$profile/runtime-packages"
printf 'RIFTVM_GUEST_AGENT_REF=%040d\n' 0 >"$fixture/sources.env"
if "$verify" "$fixture" >/dev/null 2>&1; then
  echo "verifier accepted a pin without Session Agent implementation" >&2
  exit 1
fi

echo "Verified Omarchy image-source integration contract and rejection gates."
