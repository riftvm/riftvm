# P0 validation — September 9, 2026

This record distinguishes implementation checks from physical acceptance. See
[Stability acceptance](STABILITY_TESTING.md) for the reproducible harness.

## Completed

- Default native regression suite: 65 tests passed; harness suite: 72 passed.
- Swift package core: 389 tests, one skipped, zero failures; CLI: 12 passed.
- Production app passes the executable-probe exclusion gate. The signed local
  harness is rejected by the same gate.
- Disposable Omarchy guest: file exchange, clipboard text/PNG, display resize,
  Command shortcut, lock/unlock, pause/resume, Agent restart, guest restart,
  and full-screen transitions passed.
- Continuous production input route: 10 samples of 147 characters, 64 repeated
  keys, and Return passed without pointer movement.
- Two physical displays (DELL S2722QC, 60 Hz; DELL S2725QC, 120 Hz): three rounds
  of window transfer and focus recovery passed with matching host/guest sizes.
- Host screenshot showed the complete `p0-no-mouse` marker after keyboard input,
  without an intentional pointer movement. This is a visibility check, not a
  frame-accurate latency measurement.

- Passive soak: 1,801 seconds, 180 samples, maximum gap 11 seconds; desktop
  continuously active with unchanged guest boot and Agent instance.
- Guest Fcitx5 Pinyin: `nihaoo` → preedit Backspace → `nihao`, candidate
  screenshot, and exact `你好` commit passed. The disposable guest required
  installation of the Chinese addon; the factory profile initially used US only.

The five-sample-per-backend latency comparison reported guest application p95
of 13.5 ms (Apple USB) and 9.6 ms (Guest Agent). Screenshot-based visible
observation p95 was about 374/350 ms respectively and includes the probe's
capture overhead; it must not be presented as measured host presentation time.

## Acceptance still in progress

- Real host sleep/wake and physical display unplug/replug require separate
  observation. Notification regression tests and moving windows between
  connected monitors do not prove these physical scenarios.
- Host-side Chinese IME composition has not been validated.
- Combined post-commit deletion/retyping attempts returned `你` and `好` instead
  of the expected `你好`. Their evidence is retained; the passing preedit-edit
  scenario does not qualify post-commit deletion or fast IME interaction.

Rapid UI-automation text injection produced repeated characters during manual
IME setup. The cause is not yet established; native harness input passed.
Do not treat the affected manual attempt as a successful input-method test.

The live harness was built from commit `27bc640` plus the P0 working changes.
Raw local evidence is retained under `/tmp/riftvm-p0-evidence`; it is not
included in release artifacts. The disposable workspace is stopped and retained
for the remaining physical checks.
