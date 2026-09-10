# P0 validation — September 9–10, 2026

**P0 remains open.** This record separates current evidence from older baseline
results. See [Stability acceptance](STABILITY_TESTING.md) for the procedure.

## Source and environment

- Host: Apple Silicon, macOS 27 beta; input-dispatch changes committed as
  `c8a3b43`, Command/text queue correction `ca44ad8`, and background
  Command-capture correction `841b0bb`.
- Disposable workspace: `/tmp/riftvm-p0-acceptance.riftvm`. The personal workspace
  is excluded from acceptance.
- Disposable Guest Agent: `p0-input-dispatch-2`, containing the asynchronous
  control dispatcher and disconnect key-release cleanup.
- Local evidence: `/tmp/riftvm-p0-final-evidence`, especially `dispatch-fix`.
  Harness apps are temporary, signed local tools and must not be distributed.
- Factory-image source `e27625f` pins Agent `c8a3b43`. Candidate
  `v4.0.3-riftvm.3` built successfully from verified base `v4.0.3-riftvm.2`.
  Downloaded assets and the manifest passed SHA-256 verification; its final
  image acceptance and publication are still pending.

## Verified on the current changes

- Native regression: 66 passed, zero failures or skips. Evidence:
  `dispatch-fix/native-final14.json`.
- Harness regression: 73 passed, zero failures or skips; the subsequent
  focus-preparation change also completed the harness test command successfully.
- The normal Debug app passed executable-probe exclusion. Harness builds are
  rejected by that production gate, as required.
- Guest Agent Go race tests and vet passed. The Linux ARM64 binary passed 62 tests
  inside the disposable guest (`dispatch-fix/linux-tests.log`).
- A controlled regression reproduced a two-second input-release timeout while
  status collection was blocked. After separating input from the ordered control
  queue, the release is acknowledged before the blocked status response.
- Normal view-to-Agent input delivered ten mixed-case samples exactly: 1,370
  characters without intentional pointer movement. Evidence:
  `dispatch-fix/continuous-reader`.
- User-installed Fcitx5 Pinyin and Xiaohe both completed preedit editing, candidate
  selection, post-commit deletion/retyping, and Shift switching to English. Each
  produced exact `你好 english-ok`. Kernel recordings contained 52/48 balanced
  key events with no repeats; original keyboard options and input-method service
  were restored. Evidence: `dispatch-fix/qualified-pinyin`, `qualified-xiaohe`,
  and `harness16-ime-diagnostics`.

The fresh comprehensive scenario passed at 00:41 on September 10. It verified
clipboard text/PNG, file exchange, dynamic resize, captured Command down/up,
lock/unlock, pause/resume, Agent and Guest restart, full screen, ten 147-character
samples with 64 repeats, and three rounds on both 60/120 Hz displays. No failure
report was present. Evidence: `dispatch-fix/harness17-stability-diagnostics`.
The five-sample Guest application p95 was 16.1 ms (Apple USB) and 8.9 ms
(Guest Agent); screenshot observation still includes capture overhead.
That early 1,800-second soak was interrupted to validate the Command/text
ordering bug. The later candidate soak described below completed successfully;
these are separate runs.

## Physical checks already observed

- Real host sleep: September 10, 05:23:54 UTC; wake: 05:25:04; interactive Guest:
  05:25:08. Guest boot and Agent instance IDs did not change, and the host window
  visibly showed `wake-input-ok`. This check did **not** hold a modifier during
  sleep and predates the latest input-dispatch changes.
- Physical DELL S2722QC (60 Hz) unplug/replug while S2725QC (120 Hz) stayed
  connected: host enumeration changed two → one → two displays; window migration
  and visible `unplug-input-ok`/`replug-input-ok` succeeded with unchanged Guest
  identities. Evidence: `displays-live.json`, `displays-unplugged.json`, and
  `displays-replugged.json` in the follow-up evidence root.

## Earlier baseline, not final qualification

Before the current input changes, clipboard text/PNG, file exchange, resize,
Command shortcuts, lock/unlock, pause/resume, Agent restart, Guest restart,
full-screen transitions, and three rounds of display/focus transfer passed.
Continuous input delivered ten 147-character samples and 64 repeat events.
A passive soak lasted 1,801 seconds with 180 samples and an 11-second maximum
sample gap. Core tests passed 391 with one skip; CLI tests passed 12.

The earlier five-sample latency comparison measured Guest application p95 of
13.5 ms (Apple USB) and 9.6 ms (Guest Agent). Screenshot observation p95 was about
374/350 ms and includes capture overhead; it is **not** host presentation latency.
These older runtime results require a fresh comprehensive run after the changes.

## Failures retained and fixes under validation

- AppKit delivered balanced non-repeat events while input request round trips
  reached 153–344 ms; uinput writing took only 0.147 ms in the slowest request.
  The blocked-status regression then established the control-queue problem.
- Complete synthesized chords could lose characters. The host now paces each
  SYN_REPORT boundary, including acceptance ASCII strokes. Cancellation records
  potentially held keys before waiting so cleanup can release them.
- Early IME attempts returned `你`, `好`, or an empty result. A Bash canonical
  reader is not a UTF-8-aware editor, so editing checks use Readline. Failed
  artifacts remain archived; passing preedit alone was not treated as success.
- Omarchy's `shift:both_capslock_cancel` mapping conflicts with Fcitx's Shift
  toggle ([upstream #7440](https://github.com/basecamp/omarchy/issues/7440)). The
  probe models the user's optional configuration and verifies restoration.
- IME teardown started on Return down before the monitor saw Return up. The
  harness now waits for explicit host release markers before setup/teardown;
  the subsequent Pinyin/Xiaohe sequence passed. Earlier failures remain in
  `dispatch-fix/harness11-diagnostics` through `harness15-diagnostics`.
- The first fresh comprehensive run stopped at Command+Space because the test
  window was not foreground, despite AX permission being valid. The harness now
  activates its window and verifies focus before posting the chord. Retained
  failure: `dispatch-fix/harness16-stability-diagnostics`. The next run passed after explicit activation and focus verification.

During keyboard-only idle recovery, Escape dismissed the screensaver. An
immediate Command+F followed by ordinary text then exposed concurrent forwarding:
Super was held from 00:47:11.071 to .125 while normal text reports began at .072.
The resulting output file was empty. Both paths now synchronously enqueue into
the same paced input queue, so a complete chord precedes following text. The
focused protocol suite passed 45 tests. The updated native/harness suites passed
66/73 tests, and core/CLI passed 392 (one skip)/12. The fresh `harness18` full
stability run passed. Three immediate Command+F/text repetitions returned exact
`p0-command-text-ok`, visible without pointer movement. Evidence is retained in
`dispatch-fix/command-queue`. The subsequent 1,800-second soak exited with
a generic state-validation error; no passing result was produced. Its log is
`/tmp/riftvm-p0-command-queue-soak.log`. The image Agent
source is unaffected by this host fix.

## Remaining release gates

1. Keep the final source state aligned with the passed comprehensive scenario;
   rerun affected gates if implementation changes.
2. Qualify keyboard-only idle/black-screen recovery and sleep with a held modifier;
   verify no stuck modifiers and visible input before moving the pointer.
3. Repeat final soak/physical acceptance as needed for changes affecting those
   paths. Older evidence must not stand in for changed behavior.
4. Commit the qualified source, update the image's immutable Agent pin, and
   qualify the resulting image. Local Agent replacement is not image delivery.
5. Complete final packaging/isolation and installation checks before release.

## Input-method scope

Chinese input belongs inside Omarchy. Users install/configure their preferred
engine, including Xiaohe; the factory image must not preinstall or enable a
Chinese engine. Host WeChat IME passthrough is not planned or required for P0.
Chinese clipboard exchange remains supported. See [user setup](OMARCHY_INPUT.md).

## Background host shortcut regression

The user observed host paste and screenshot shortcuts reaching a background VM.
The capture focus probe checked AppKit's retained key window but omitted
application activation. Commit `841b0bb` requires `NSApp.isActive` as well as
the key window and Guest responder. Regression coverage includes Command+V and
Command+Shift+A with a retained background key window. All 67 native integration
tests passed in `Test-BackgroundFocusTests-2026.09.10_01-10-56--0700.xcresult`
under `/tmp/riftvm-p0-final-native/Logs/Test`. The old harness was exited to
stop intercepting host input. A live foreground/background check with the new
binary remains required; unit tests alone do not close that gate.

## Factory candidate first boot

Candidate `v4.0.3-riftvm.3` passed raw-disk SHA-256 verification, ASIF
conversion, and signed-manifest/image validation against the app's trusted key.
An obsolete local signing key was correctly rejected; the established release
key matched app trust. Commit `3221323` adds an optional signing-key preflight
before conversion; the complete factory-tool regression script passed.

Fresh temporary workspace `/tmp/riftvm-p0-factory-firstboot.riftvm` completed
initialization and reached the desktop with Agent `c8a3b43`. Evidence is in
`dispatch-fix/candidate-firstboot`. Actual DPMS black screen was observed, then
Escape restored display without pointer movement. However, the immediately
following burst did not appear; a subsequent burst displayed `keyboard-wake-ok`.
The first burst reached the host as 29 balanced key pairs, with 58 Agent
acknowledgments and a maximum 3.957 ms round trip. This does not prove Guest
application delivery. Wake qualification remains open. A fresh candidate soak
is running; no passing result is claimed yet.

The follow-up controlled DPMS probe passed: Guest monitor JSON recorded
`dpmsStatus=false` before input and `true` afterward. A plain Bash reader
received exact ` wake-immediate-input-ok\n`, including the wake space, and
the complete result was visible without pointer movement. The earlier
Escape/text behavior reproduced with the display already awake in the default
Emacs-mode terminal. It is retained as a terminal-editing control, not evidence
of DPMS input loss. Probe and before/after files are archived in
`dispatch-fix/candidate-firstboot/p0-dpms-*`. This closes the keyboard-only
DPMS wake check; actual host sleep with a held modifier remains separate.

## Candidate soak and current regression results

The candidate soak passed: 1,800 continuous seconds, 180 samples, maximum
11-second sample gap, unchanged Guest boot and Agent identities, and continuous
active/provisioned session state. Evidence: `dispatch-fix/candidate-soak.json`
and `candidate-observe-soak-diagnostics`. The test used host `ad8ea32` and the
candidate Agent `c8a3b43`; later changes affect release/diagnostic tools only.

The current harness suite passed 74 tests with no skips or failures
(`dispatch-fix/harness19-tests.json`). The candidate's unused offline workspace
passed protected pre-update snapshot restoration with exact marker restoration
and a ready workspace (`candidate-offline-rollback.json`). This is not proof
of an in-Guest package update rollback.

Optional Chinese packages were installed only in the disposable candidate Guest:
`fcitx5-chinese-addons 5.1.14-1`, `libime 1.1.16-1`. A mirror timeout initially
prevented installation; retry succeeded. The immutable factory remains unchanged.
Candidate IME and full lifecycle runs, held-modifier host sleep, screenshot
shortcut confirmation, and final distribution gates remain open. Factory asset
upload is pending explicit approval after automatic review rejected the attempt.

### Candidate IME follow-up (2026-09-10)

Harness 19 failed Pinyin with `你 english-ok`; all 26 key-down/up pairs reached
the Guest kernel in order without held keys. Harness 20's explicitly diagnostic
stage-capture run produced `你好 english-ok`. A subsequent run with stage capture
disabled passed both Pinyin and Xiaohe, including preedit and postcommit deletion.
This single fast-path success does not resolve the earlier intermittent failure.
Evidence: `dispatch-fix/candidate-ime-fast-h20-summary.json`; original failure
and stage-capture artifacts are retained separately.

The full system refresh candidate `v4.0.3-riftvm.4` was reconstructed with part,
archive, and raw-image hashes verified, converted to ASIF, signed, and verified
against the application's trusted factory key. Its disposable workspace reached
the provisioned desktop. Full input acceptance and publication remain outstanding.

The fresh Guest's `checkupdates` returned exit 2 with no available packages and
no stderr, but the first-run Wi-Fi script unconditionally displayed Update System.
Image source commit `7e8e7ae` now notifies only when a successful package check
returns updates. Six notification contract cases passed. Full-image workflow
`34463094630` for `.5` is building; this is not yet a published factory.

Short native CUA typing on `.4` intermittently repeated characters. Later kernel
observations recorded balanced RiftVM Keyboard events without repeats; the Apple
virtual keyboard produced no events during the monitored sample. Both monitored
and subsequent unmonitored samples passed, so monitoring is not a demonstrated
fix. With the same harness on `.3`, `echo abcdef` and the full alphabet also
displayed exactly without pointer movement. These samples do not close the
intermittent input defect or prove a new-image regression. Evidence is retained
in `dispatch-fix/full-refresh-kernel-monitor` and `old-image-input-comparison`.

### Cross-display host shortcut follow-up

Commit `d94892f` additionally requires NSWorkspace frontmost process ownership
before intercepting Command shortcuts. Native regression completed successfully.
With harness 20 and the temporary Guest running, TextEdit copied and pasted the
marker, then pasted it again after Window > Move to DELL S2725QC. AX text showed
three identical lines. This verifies app-targeted CUA events and an actual native
window move; physical global screenshot hotkeys remain a separate check.
Evidence: `dispatch-fix/host-paste-cross-display-h20.json`.

A subsequent harness 20 stability run stopped at the lock probe because the
window lost keyboard focus. It is not a pass, and the VM remained available.
A user-coordinated uninterrupted foreground test interval is pending.

### Connection transition follow-up

Commit `1dcf1c4` clears queued input on pause, disconnect, and stop and gives
each dispatcher a generation. A canceled old dispatcher cannot clear a new
dispatcher or its queue. Release compilation passed, as did the three existing
connection-suspension tests. Those tests cover suspension reasons, not live
queued-event delivery. The normal build also passed production probe isolation.

Harness 21 paused and resumed the disposable `.3` Guest through the native
toolbar. Integration became ready, but the following `echo resume-input-ok`
sample repeated characters and failed. All 21 native key pairs were balanced,
with zero native repeat events and 42 input acknowledgments. Inferred write
spacing for the repeated `c` was 7.7 ms; no pair exceeded 68.1 ms. A subsequent
`echo $TERM` sample did not appear, including after Return. Four individual
`pressKey` calls then displayed `echo` correctly. This does not establish a
CUA-specific defect or resolve physical input latency. Evidence is retained in
`dispatch-fix/h21-pause-resume-repeat` and `h21-post-resume-missing-text`.

Image workflow `34463094630` completed successfully. Candidate `.5` raw-image
reconstruction passed all supplied release checks after downloading the required
package inventories.

### Refreshed image recovery validation

Candidate `.5` passed ASIF byte comparison, signing, and verification against the
application's trusted public key. A fresh disposable workspace completed owner
initialization and reached the desktop with integration ready. The initial
desktop showed Learn Keybindings without the former unconditional Update System
notification; this observation does not replace a package inventory check.

The native Updates > Prepare for Omarchy Update action gracefully stopped the
Guest and created a protected Before Omarchy update recovery point. Another boot
and clean shutdown changed the Guest disk hash. Recovery through the native menu
restored its exact snapshot hash, then the restored Guest booted, accepted the
original test account, and advertised an active desktop with integration ready.
This qualifies the generic disk recovery flow; an actual package update was not
performed. Evidence: `dispatch-fix/image5-update-preparation`, including before/
after disk hashes and post-restore boot readiness. Input failures remain open.
