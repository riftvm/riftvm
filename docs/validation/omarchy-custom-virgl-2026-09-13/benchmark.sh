#!/bin/bash
set -eu
label=${1:?backend label required}
out=/mnt/riftvm-shared/gpu-comparison/$label
mkdir -p "$out"
eglinfo -B > "$out/eglinfo.txt" 2>&1
pacman -Q mesa libglvnd glmark2 > "$out/packages.txt"
for run in 1 2 3; do
  glmark2-es2-wayland --off-screen --frame-end finish --size 1280x720 \
    -b 'build:use-vbo=true:duration=10.0' \
    -b 'shading:shading=phong:duration=10.0' \
    -b 'bump:bump-render=normals:duration=10.0' \
    -b 'terrain:duration=10.0' \
    -b 'refract:duration=10.0' > "$out/run-$run.txt" 2>&1
 done
printf 'completed\n' > "$out/done.txt"
