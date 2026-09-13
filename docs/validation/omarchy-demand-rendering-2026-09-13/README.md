# Omarchy demand rendering — September 13, 2026

Host branch `perf/omarchy-demand-rendering`, based on `bfceffa0af92874daac93c04793a822738c202af`
(RiftVM 0.1.20 plus its cask synchronization). The local signed acceptance build
contains the same production presentation changes as this PR. A later comment
relocation changes no executable logic. No release or factory is published here.

## Findings and changes

Three independent mechanisms kept the desktop rendering continuously:

1. The Host redrew its live scanout on a repeating 60 Hz timer. If a notification
   arrived while acquisition/render was in flight, it was discarded and the next
   timer tick rescued it. Simply deleting the timer would lose the last frame.
2. Rift Agent's session loop repeatedly set Hyprland `debug:vfr=false`.
3. The factory image's separate `omarchy-riftvm-display-watch` did the same on
   its one-second mode reconciliation loop. Updating only the Agent was not enough.

The Host now retains coalesced pending damage, drains it on completion, and
stops work after the final frame. Normal frames use no refresh timer. Failed
acquisition/render gets at most three one-shot retries; new damage resets the
budget. Visibility restoration and geometry changes request a frame. Existing
producer-context synchronization and off-main drawable acquisition remain intact.
Both Guest overrides are removed; the compositor/user owns VFR configuration.

This does not establish a new Hyprland upstream root-cause diagnosis. The old
workaround predated existing producer-context flush/fence and main-thread wait
fixes. This work demonstrates that the tested current stack works without that
workaround, and closes the Host's reliance on a later timer tick for final damage.

## Required components

The companion `riftvm-omarchy-aarch64-image` branch with the same name removes
the display-watcher override and tests that actual mode changes still apply.
The updated Rift Agent must also be installed/consumed by the next factory build.
A Host-only upgrade cannot undo old overrides inside an existing Guest. These
PRs do not silently migrate user disks or publish a new factory. Ship and qualify
the corresponding Host, Agent, and image watcher together.

Only the disposable `Performance Test (Temporary)` Guest was started. It used
4 vCPUs, 8 GiB RAM and the existing factory v4.0.3-riftvm.5 with candidate Agent
and watcher installed for testing. The personal workspace was not started.
Guest versions are in `packages.txt`; tested binary/script hashes are retained.
The watcher's final source has only an indentation cleanup after that hash.

## Correctness validation

- After reboot, VFR was true with `set:false` (the compositor default), without
  an explicit enable command. It remained true after the frame probe.
- Ten red/green terminal update pairs ran without pointer input; the final blue
  frame was visibly present after the script finished. The accompanying file is
  a Guest execution marker; visible correctness was separately observed in UI.
- The final run passed text/PNG clipboard in both directions, file import and
  shared-folder round trips, one resize round trip, and all six display/focus
  cycles across DELL S2722QC (60 Hz) and DELL S2725QC (120 Hz). The retained
  `multi-display-focus.json` was produced by that final run at 15:04 local time.
- Pause/resume accepted a keyboard-only shell command immediately; `resume.txt`
  contains its exact nonce. This does not measure input-to-photon latency.
- A delayed purple frame generated while minimized was visible on restoration;
  VFR remained true. The temporary VM was subsequently stopped.
- Six timing/demand tests and 66 native Omarchy integration tests passed. Tests
  cover final damage during an in-flight frame, coalescing, idle termination,
  bounded retries, cancellation, visibility, and existing lifecycle behavior.
- Go tests, the Linux/arm64 Agent build, watcher regression/syntax checks, normal
  Release build and production acceptance-probe exclusion passed.

Earlier display runs stopped at the harness's focus/window guard. The final
uninterrupted repeat passed all six cycles; the earlier attempts are not counted
as successful qualification. Early VFR samples taken before discovering the
second Guest override are also excluded.

## Controlled short idle sample

Same candidate binary, Guest, visible terminal, resolution and resource allocation.
The terminal cursor was hidden. Each phase settled for 10 seconds, then sampled
for 15 seconds; VFR false/true was recorded before and after each phase. Both
static screens were visually checked. No build or test suite ran during sampling.
`ps` was sampled once per second for the app and its single VM service process.
CPU percentages use macOS process accounting (100% is one CPU), not whole-system
utilization or measured watts. The observer caught 15 and 14 samples respectively.

| Process | Continuous rendering | Demand rendering |
| --- | ---: | ---: |
| RiftVM application mean CPU | 14.280% | 0.314% |
| Virtualization VM service mean CPU | 15.053% | 4.250% |

See `idle-samples.json` and the four phase option snapshots. This is a short
within-candidate VFR comparison, not an old/new binary benchmark, a Try Omarchy
comparison, or a universal power-saving claim. RSS values are retained but this
short experiment does not establish memory savings. The display-mode watcher
still polls once per second; demand rendering does not eliminate every Guest wakeup.

A preceding four-phase exploratory run produced inconsistent later phases and
was followed by visibility/lock-state interference. It is retained separately
as `exploratory-idle-samples.json` and is excluded from the result table. An
attempted repeat reached the lock screen before launching its probe and was
also excluded. A short pair avoids those long-idle confounders.

## Reproduction and limits

Run `guest-frame-probe.sh` and `guest-minimize-probe.sh` in an already provisioned,
disposable Guest using the candidate components. Observe the display independently
of the Guest marker files. The examples use the test shared-folder layout.

For CPU sampling, start `host-idle-probe.py APP_PID VM_SERVICE_PID PHASE_FILE
OUTPUT_JSON`, then run `guest-idle-probe.sh` in the Guest. The default output
folder is `/mnt/riftvm-shared/vfr-final`; PHASE_FILE is its Host-side `phase.txt`.
Use a fresh output folder and keep the window visible. Confirm actual VFR state,
Guest readiness, and absence of screen locking/animations throughout the sample.
The script restores the prior VFR option and terminal cursor on exit.

Static demand rendering may emit no frame timing windows. Use a changing workload
for the existing latency gate rather than treating no idle frames as a failure.
No new complex 3D benchmark, physical display hot-plug, real Host sleep, or broad
GPU/application compatibility qualification is claimed. Fresh signed factory
qualification remains part of the coordinated release, not this local PR run.
