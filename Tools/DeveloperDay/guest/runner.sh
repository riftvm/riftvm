#!/bin/bash
# Runs each job script dropped into jobs/ beside this file in its own process,
# inside the desktop session. Test machines only.
dir="$(cd "$(dirname "$0")" && pwd)/jobs"
systemctl --user stop hypridle.service 2>/dev/null; systemctl --user mask --runtime hypridle.service 2>/dev/null; pkill -x hypridle
# Omarchy's shell keeps its own idle timer, and a job runner produces no input.
# Without this, shell.json's screensaver (150s) and lock (300s) cover the screen
# part way through a run, and anything that reads the screen measures those.
omarchy-toggle-idle stay-awake >/dev/null 2>&1
echo "runner $$ $(date -Is) WAYLAND_DISPLAY=$WAYLAND_DISPLAY dir=$dir" > "$dir/runner.alive"
while true; do
  for job in "$dir"/*.sh; do
    [ -e "$job" ] || continue
    name="${job%.sh}"
    mv "$job" "$name.running" || continue
    (
      ( cd ~ && timeout "${JOB_TIMEOUT:-2400}" bash "$name.running" ) > "$name.out" 2>&1
      echo $? > "$name.rc"
      mv "$name.running" "$name.done"
    ) &
  done
  sleep 1
done
