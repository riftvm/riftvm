#!/bin/bash
sleep 10
printf '\033[2J\033[H\033[45m LATEST PURPLE FRAME GENERATED WHILE MINIMIZED \033[0m\n'
printf 'generated\n' > /mnt/riftvm-shared/vfr-final/minimized.txt
hyprctl -j getoption debug:vfr > /mnt/riftvm-shared/vfr-final/vfr-after-resume.json
