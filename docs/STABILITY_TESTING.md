# Stability acceptance

RiftVM's normal build does not compile the automatic Omarchy input, clipboard,
lock, restart, or full-screen probes. Setting acceptance environment variables
cannot enable them in that build. Passive diagnostics and normal guest input
remain available.

The implementations live in `Tools/OmarchyAcceptanceHarness`. Only an explicit
`RIFTVM_ACCEPTANCE_HARNESS` Swift build includes them. The local harness has a
separate app name, displays a testing banner, and accepts only an explicitly
selected temporary workspace. It must never be installed or distributed as
RiftVM. Production packaging and installation verification reject the harness
marker and executable probe signatures.

## Build and run

Build the local tool with a source-qualified VirGL runtime available:

```sh
scripts/build-omarchy-acceptance-harness.sh /tmp/riftvm-acceptance-build
```

Set `RIFTVM_SIGNING_IDENTITY` to the development team's Developer ID identity when
using the installed app's matching provisioning profile. The harness retains
the app identifier for local permission continuity; the executable is explicitly
marked as a harness and fails the production release gate.

Create a disposable workspace with `omarchy-workspace-acceptance-tool`, then run:

```sh
python3 Tools/OmarchyAcceptanceHarness/run.py \
  '/tmp/riftvm-acceptance-build/RiftVM Acceptance.app' \
  /tmp/my-acceptance.riftvm --scenario stability
```

The launcher prompts for the temporary guest password without echoing it. Start
only that named workspace in the Control Center. It refuses a non-temporary
workspace, a normal app, an already-running RiftVM instance, or nonempty
Diagnostics. Archive the previous Diagnostics before each run. Each launch gets
its own environment; no global defaults or launch environment are changed.

Scenarios:

- `lifecycle`: clipboard and sharing, resize, Command shortcuts, lock/unlock,
  pause/resume, Agent restart, guest restart, and full-screen transitions.
- `stability`: lifecycle followed by continuous input, input latency comparison,
  and three rounds of display/focus transitions across physical displays.
- `displays`: sharing/clipboard setup followed by display and focus transitions.
- `continuous-input` and `input-latency`: isolated input measurements.
- `ime`: guest Fcitx5 Pinyin and Xiaohe double-pinyin composition, candidate
  capture, preedit/post-commit backspace, and Shift switching to English.
  Requires user-installed `fcitx5-chinese-addons` in the disposable guest;
  temporarily configures each engine and restores the profile, keyboard options,
  and input-method service after each probe.
- `observe`: passive heartbeat collection, with no automatic lifecycle probes.

The comprehensive scenario requires at least two connected displays. A missing
prerequisite or failed probe is not a pass. Test failure leaves the VM available
and prevents later automatic scenarios from starting.

## Evidence and limits

Retain `Diagnostics` before removing the temporary workspace. Review the first
failure, not only the latest success file. Start a fresh evidence directory for
each independent run; old reports do not prove that the current run passed.

The input latency probe measures delivery and the guest compositor's visible
surface. It does not by itself prove when the host display showed that surface.
Pair it with a host screenshot or recording taken without pointer movement.
Chinese text transferred through the clipboard is not an input-method test:
verify composition, candidate selection, commit, and backspace using the guest
input method. Host input-method passthrough is not planned.

For a soak run, use `omarchy-soak-acceptance-tool` after the automated scenarios
finish. Record the requested and observed duration; a short run does not prove
hours of stability. Real host sleep/wake and physical display disconnect/reconnect
must be recorded separately from synthetic notification or window-move tests.

## Regression gates

Run `RiftVMKeyboardTests` twice: once with default build settings and once with
`SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG RIFTVM_ACCEPTANCE_HARNESS'`. Use separate
DerivedData directories. The default suite covers production input and isolation;
the harness suite additionally tests probe implementations.

Run `scripts/verify-production-test-isolation.sh` on the normal app and require
success. Run it on the harness and require rejection. Standard release scripts
perform this check automatically. No release may claim a hardware, input-method,
or sleep scenario passed when its evidence is missing.

## Physical checks

Use the `observe` scenario and the disposable workspace for checks that require
someone at the Mac. Retain timestamps and screenshots alongside the JSON reports.

1. With the guest focused, hold a modifier, put the Mac to sleep, then wake and
   unlock it. Verify ordinary typing, shortcuts, and that no modifier remains
   stuck. Repeat typing before moving the pointer.
2. Switch to another Mac app and back several times; verify the guest neither
   captures input while unfocused nor loses keyboard input after focus returns.
3. Disconnect and reconnect an external display. Verify the guest remains usable,
   fits the new window, and accepts input without a pointer movement.
4. Install a Chinese input method in the disposable guest as a user would.
   The factory image must not preinstall or enable a Chinese input method.
   Inspect the candidate popup, select a candidate, commit text,
   delete a character, and switch back to English using the guest input method.
   Include Xiaohe double pinyin and Chinese clipboard exchange.
   Follow [the user setup guide](OMARCHY_INPUT.md) when testing Shift switching:
   Omarchy's default two-Shift Caps Lock mapping conflicts with that shortcut.

Keep these results separate from automated window transitions, simulated sleep
notifications, clipboard transfer, and guest-only compositor screenshots.
