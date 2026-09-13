# Omarchy Custom VirGL 3D comparison — September 13, 2026

## Scope

This compares the dedicated Omarchy graphics path before and after connecting
Custom VirGL. Both runs use the same disposable workspace, 4 vCPUs, 8 GiB RAM,
and installed Guest packages. The personal Omarchy workspace was not opened.
No lock or sleep tests were requested by the test runner.

The Apple Virtio baseline uses the local acceptance build from source `0457da3`.
The Custom VirGL candidate uses the working tree based on `79b318f`, built as
`/tmp/riftvm-custom-omarchy-harness3/RiftVM Acceptance.app`. These are local
acceptance programs, not a new published release. The old build is only an A/B
reference: the new Omarchy path has no Apple Virtio fallback.

## Renderer evidence

- Apple Virtio: EGL Wayland and glmark2 report `llvmpipe (LLVM 22.1.8, 128 bits)`.
- Custom VirGL: EGL Wayland and glmark2 report `virgl`.
- Custom host runtime reports `[stage3] ANGLE Metal EGL 1.5 initialized`.
- Guest Mesa is `26.2.2-arch1.1`; glmark2 is `2023.01` in both runs.
- The Guest advertises GLES 3.0 on VirGL, versus GLES 3.2 on llvmpipe. This
  comparison uses the same GLES 2 scene shaders and is not evidence of Vulkan
  or newer OpenGL feature support.

Raw EGL information, package versions, and all six run logs are retained in
this directory. The benchmark command is in [benchmark.sh](benchmark.sh).

## Method

Run glmark2-es2-wayland at 1280×720 with `--off-screen --frame-end finish`.
Each run contains five real rendering scenes, ten seconds per scene; repeat
three times. Offscreen rendering avoids compositor refresh-rate capping.
`finish` waits for submitted GPU work at each frame boundary, so the result
cannot count an arbitrarily deep queue of unfinished GPU commands as frames.
The benchmark target is exactly 1280×720 on both backends. The surrounding
desktop differs: Apple selects 2048×1319 at scale 2, while Custom VirGL selects
1024×656 at scale 1 for the same host window. This is a product-path comparison,
not an isolated driver microbenchmark; compositor overhead is a possible
confounder even though measured scenes render offscreen.

No shader or package changes occur between backends. Baseline and candidate
run sequentially, not concurrently; no host build runs during measured scenes.

FPS below is calculated as 1000 divided by the median reported frame time.
Ratios use the same median times, not rounded integer FPS from the logs.

| Scene | llvmpipe FPS | VirGL FPS | Speed ratio |
| --- | ---: | ---: | ---: |
| Model build, VBO | 623.8 | 604.2 | 0.97× |
| Phong shading | 231.3 | 607.2 | 2.62× |
| Normal-map bump | 551.3 | 603.1 | 1.09× |
| Terrain | 5.6 | 255.8 | 45.48× |
| Refraction | 22.7 | 440.3 | 19.39× |

This supports acceleration of the tested complex 3D workloads. The simple
model workload is effectively unchanged and slightly slower in this sample.
It does not establish a universal speedup, total VM power reduction, or
application/game compatibility. Idle host CPU and desktop refresh are not used
as the primary performance evidence.

## Rendering correctness

The onscreen terrain and refractive rabbit were visibly rendered through the
Custom VirGL window. glmark2 output validation passed for model build, Phong
shading, and normal-map bump. Terrain and refraction returned `Unknown`, not
`Success`; those scenes have visual observation only. See the retained
[validation log](custom-virgl/validation.txt) and
[onscreen run](custom-virgl/onscreen.txt).

## Integration checks

The later candidate in `/tmp/riftvm-custom-omarchy-harness6` retains the same
renderer and adds input/lifecycle/display fixes. Login with authenticated uinput
works. Fullscreen negotiation now changes Guest resolution from 1024×656 to
1920×1008 and the Guest acknowledges it; exiting fullscreen restores the window
layout. Pause/resume returns the visible desktop, and typing directly after
Resume reaches the Guest without an extra click. The resulting shared-folder
file contains `focus-fixed`.

Five targeted Xcode integration tests passed: login/desktop input policy,
pointer-button release on host overlay, key down/repeat/up, held-key release
on disconnect, and avoiding duplicate Command modifiers. Five Core builder
tests also passed. No sleep or lock tests were executed.

The no-lock `displays` scenario additionally passed shared-folder round trips
and Agent clipboard text/PNG round trips in both directions. Its old display
assertion compared Guest mode with Retina backing pixels and failed despite
the actual 880×528 Custom mode being correct for the logical view. The probe
has been updated to retain backing-pixel evidence separately and require an
exact match to the Custom VirGL requested mode. Harness 8 passed all six
window migration/resize checks across a 60 Hz DELL S2722QC and a 120 Hz DELL
S2725QC; see [the report](custom-virgl/multi-display-harness8.json).
The probe also restores the original window frame rather than passing the
toolbar-excluding content layout size to `setContentSize`. The latter shrank
the test window on each cycle. The final candidate removes redundant delayed
refreshes because the Custom VirGL backend already coalesces geometry changes.

Harness 10, with these fixes, passed the final six-check display cycle on both
monitors with exact 880×528 Guest modes and recovered focus. The original
window size remained constant across all cycles. See the
[final display report](custom-virgl/multi-display-final.json) and
[integration log](custom-virgl/integration-final.txt).

A separate unprovisioned disposable workspace completed native owner setup,
reached the Hyprland desktop, accepted Command-Return, and wrote
`fresh-owner-input-ok` through the shared folder. Restarting that workspace
returned to the login screen and then an authenticated desktop. See the
[fresh-owner lifecycle](custom-virgl/fresh-owner-lifecycle.json),
[input result](custom-virgl/fresh-owner-input.txt), and
[restart readiness](custom-virgl/restart-readiness.json). The observation
schema calls the boot/login interval “locked”; no lock command was executed.

Creating a protected backup, restoring that just-created backup, and booting
the restored temporary disk succeeded through the UI.

A separately signed test copy with its bundled VirGL directory removed failed
before starting a VM. It displayed the missing library names and did not select
Apple graphics ([fault-injection record](custom-virgl/missing-runtime.txt)).
“Stop and Enable Recovery” returned immediately to the stopped
state. This caught and fixed command observers being installed too late when
initialization failed. Three final targeted Xcode tests passed (zero skipped):
no-machine stop/recovery, login/desktop input policy, and pointer-button release.

Normal Release compilation and the production test-isolation gate are checked
separately from the local-only acceptance app. This report does not imply a new
published app version or universal 3D application compatibility.
