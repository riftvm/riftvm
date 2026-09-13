#!/bin/bash
set -eu
out=/mnt/riftvm-shared/vfr-final
mkdir -p "$out"
hyprctl -j getoption debug:vfr > "$out/vfr-after-reboot.json"
sha256sum /usr/local/sbin/rift-agent /usr/local/libexec/omarchy-riftvm-display-watch > "$out/guest-components.sha256"
systemctl --user show rift-session-agent.service omarchy-riftvm-display-watch.service -p ExecStart -p ActiveState > "$out/services.txt"
pacman -Q hyprland aquamarine mesa > "$out/packages.txt"
for i in $(seq 1 10); do
 printf '\033[2J\033[H\033[41m RED FRAME %s \033[0m\n' "$i"
 sleep 1
 printf '\033[2J\033[H\033[42m GREEN FRAME %s \033[0m\n' "$i"
 sleep 1
done
hyprctl -j getoption debug:vfr > "$out/vfr-after-animation.json"
printf '\033[2J\033[H\033[44m FINAL BLUE FRAME 10 -- NO POINTER INPUT \033[0m\n'
printf 'complete\n' > "$out/animation-result.txt"
