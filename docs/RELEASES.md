# Release notes

RiftVM publishes one GitHub release per `riftvm-vX.Y.Z` tag. This file is the
in-repository record of what each release contains, and the convention that
keeps new notes consistent.

## Where notes live

- **GitHub Releases** is what users read. The note body is generated from the
  commits in the release at publish time, not from `--generate-notes`.
- **This file** keeps the same note, versioned with the source, so the reason
  for a release stays reviewable after the tag.

`scripts/release-notes.sh` keeps the two in step:

- `prepare <version>` adds a note section when a release has none, built from the
  commits between the previous release and this one. The release scripts call it,
  so a missing note never blocks a release; a section that already exists is
  never touched.
- `extract <version>` prints the note as the GitHub release body, with links made
  absolute. `publish-release.sh` calls it, so the published body comes from this
  file.
- `check` reports releases without a section for manual use.

### What the generated note contains

- Commit subjects become bullets, grouped by conventional-commit prefix:
  `feat` under Features, `fix` under Fixes, `perf` under Performance, and
  `refactor`, `chore`, `test`, `ci`, and `build` under Internal. A subject
  without a prefix stays under Changes, so nothing is dropped.
- A commit's first body sentence is appended to its bullet as `— <sentence>` when
  it adds something the subject does not already say. The body is soft-wrapped,
  so the generator reads the first paragraph as one line, stops at a blank line
  (a bullet list in the body does not bleed in), and drops a sentence longer than
  240 characters. That sentence is where the motivation goes, and it is why a
  commit body matters even when the diff is obvious.
- `Prepare RiftVM X.Y.Z` is excluded.

The result is a usable changelog without any extra work. Edit the section before
publishing when a change needs user-facing wording, a known issue, or a
validation claim; what the generator cannot write is the validation and the
stated non-claims, so add those when they matter.

## How to write a release note

1. Write the commit subject as the sentence a user would read:
   `fix(catalog): point the Linux image catalog at riftvm.com`, not
   `fix null check`. Use `feat:`, `fix:`, `perf:`, `docs:`, `refactor:`,
   `test:`, `ci:`, or `build:` when the commit fits one.
2. Put the reason in the commit body's first sentence, before any blank line.
   `The old host answered 404, so the list never refreshed` survives into the
   note; a bare subject does not explain anything.
3. When you edit the generated section, describe **what changed for a user and
   why**, and keep it short. Internal refactors do not belong in user notes.
4. State the validation you actually ran, with numbers, and say what the release
   does **not** claim. Do not imply an unverified hardware, sleep, or
   input-method scenario passed.
5. List open known issues that affect users of this build, even when the release
   does not touch them.
6. Name the supported images and requirements only when they changed.

Template:

```markdown
RiftVM X.Y.Z <one sentence: what this release is for.>

Requires **macOS 27 or later and Apple silicon**.

### Features

- <user-visible change — its motivation>

### Fixes

- <user-visible fix — its motivation>

### Validation

<what was actually run, with counts. Say what is not claimed.>

### Known issues

- <open issue that affects this build>

Install or update with Homebrew:

```sh
brew install --cask riftvm/tap/riftvm
brew upgrade --cask riftvm
```

Or download the app archive below.
```

## 0.1.16

RiftVM 0.1.16 stops or saves a running guest before it quits, and keeps the
running workspaces visible in the menu bar.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- Quitting no longer kills the guest. RiftVM asks every running machine to end
  cleanly first — macOS guests save their state, Omarchy shuts its guest down —
  and shows a small progress panel while that happens, so quitting from the Dock
  or from the menu bar no longer makes the app vanish mid-shutdown. A guest that
  does not respond within 15 seconds is stopped so Quit cannot hang.
- Closing an Omarchy window while its guest runs now asks "Stop Omarchy and
  Close?" and keeps the window open with the stop progress until the guest is
  down, matching what macOS workspaces already did. Linux guests cannot save
  machine state, so the next start is a full boot.
- A menu bar item shows what is running: each workspace with its state, plus
  Pause, Resume, Save State and Stop, Stop, a way back to its window, the
  control center, and Quit. It also keeps RiftVM reachable once every workspace
  window is closed.

### Validation

Both jobs of the RiftVM GitHub Actions workflow pass on the macOS 27 Xcode 27
runner image: the macOS job runs the core and CLI tests, the VirGL runtime tests
(26 tests), the project synchronizer, the Debug app build, the integration-test
build-for-testing, and the factory, Overlay, and release-gate scripts; the
guest-agent job runs the Go tests and the ARM64 cross-compile.

The quit drain and the Omarchy close policy are covered by unit tests in
`RiftVMIntegrationTests` (11 tests), and a launch/quit smoke test was run against
the built app.

Release signing, notarization, staple, Gatekeeper assessment, the production
entitlement allowlist, the visible-window check, a real import and boot of a
locally built AArch64 Omarchy preinstalled image, and the published Homebrew cask
were verified by the release pipeline.

This release does not change guest input, graphics, or recovery behavior, and it
does not claim new validation of the menu bar item or of quitting with a running
guest on a real machine.

### Known issues

- An intermittent guest input defect remains open: shortly after pausing and
  resuming, typed characters can repeat or a line can be lost. See
  [P0 validation](P0_VALIDATION.md).

## 0.1.15

RiftVM 0.1.15 shows how far creation has actually come, and names each workspace
window after the workspace.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- Preparing a workspace now opens a rift: two lit lips widen with the real
  download and install progress, light spills between them, and the workspace
  icon appears in the open seam when creation finishes. The previous effect
  repeated the same tilted bars in every phase, so it read as decoration next to
  a progress bar that was doing the work.
- A workspace window is titled with the workspace name instead of "Workspace",
  so several open workspaces can be told apart from the title bar and the Window
  menu. A rename in the control center reaches the title the next time that
  workspace opens.

### Validation

Both jobs of the RiftVM GitHub Actions workflow pass on the macOS 27 Xcode 27
runner image: the macOS job runs the core and CLI tests, the VirGL runtime tests
(26 tests), the project synchronizer, the Debug app build, the integration-test
build-for-testing, and the factory, Overlay, and release-gate scripts; the
guest-agent job runs the Go tests and the ARM64 cross-compile.

Release signing, notarization, staple, Gatekeeper assessment, the production
entitlement allowlist, the visible-window check, a real import and boot of a
locally built AArch64 Omarchy preinstalled image, and the published Homebrew cask
were verified by the release pipeline.

This release does not change guest input, graphics, or recovery behavior.

### Known issues

- An intermittent guest input defect remains open: shortly after pausing and
  resuming, typed characters can repeat or a line can be lost. See
  [P0 validation](P0_VALIDATION.md).

## 0.1.14

RiftVM 0.1.14 fixes the Linux image list in the create-machine flow.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- The app now refreshes its catalog from `https://riftvm.com/catalog/linux.json`.
  It previously requested a retired personal host that redirects to a 404 page,
  so the online list could never load and every workspace silently fell back to
  the built-in list.
- The built-in fallback, `docs/catalog/linux.json`, and the published catalog
  now agree entry for entry: Ubuntu Server 24.04.4, Ubuntu Desktop 24.04.4,
  Debian 13.6.0, and Fedora Server 44. The fallback previously offered Debian
  13.1.0 and Fedora 42, which the published catalog had already replaced.
- Debian and Fedora carry a size and SHA-256, so RiftVM checks free disk space
  before starting a download instead of failing partway through.
- A catalog contract test runs as part of every release, so the app, the
  repository, and the published catalog cannot drift apart again.

### Validation

Release signing, notarization, staple, Gatekeeper assessment, the production
entitlement allowlist, the visible-window check, a real preinstalled-image
import and boot, and the published Homebrew cask were all verified by the
release pipeline. `scripts/test-linux-catalog.sh` verifies the three catalog
copies and rejects drift.

This release does not change guest input, graphics, or recovery behavior.

### Known issues

- An intermittent guest input defect remains open: shortly after pausing and
  resuming, typed characters can repeat or a line can be lost. See
  [P0 validation](P0_VALIDATION.md).

## 0.1.13

RiftVM 0.1.13 hardens guest keyboard input and shortcut ownership.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- Modifier intent is preserved for translated characters and right-side keys, so
  chords and shifted input survive translation instead of dropping a modifier.
- Command chords are serialized with the text that follows them. Previously a
  chord and the next line of text could be delivered together, which produced
  empty or interleaved output.
- Guest keys are released when input delivery fails, when the connection is
  paused, disconnected, or stopped, and queued input from a previous connection
  is discarded.
- App-targeted Command shortcuts are captured only while the RiftVM window owns
  the frontmost process, so host paste and screenshot shortcuts are no longer
  intercepted while another application is in front.
- Guest input stays responsive while control operations are in flight.
- The factory tool checks the signing key against the app's trusted key before
  converting an image.

### Validation

67 native integration tests passed. Guest Agent Go race tests and vet passed,
and 62 Guest Agent tests passed inside the disposable guest. The candidate soak
ran 1,800 continuous seconds with unchanged guest boot and Agent identities. A
candidate image first boot, DPMS wake, and protected recovery-point restoration
were observed. Evidence and the open input findings are recorded in
[P0 validation](P0_VALIDATION.md).

This release does not claim that the intermittent input defect is closed, and it
does not claim new validation of physical display hot-plug or real host sleep
with a held modifier.

### Known issues

- The intermittent guest input defect is still open; see
  [P0 validation](P0_VALIDATION.md).

## 0.1.11

RiftVM 0.1.11 connects updates to the signed factory channel and adds recovery
points.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- Creating a fresh workspace from the latest signed factory image is now
  connected to image checks, and the existing workspace is retained.
- A guided pre-update recovery point stops Omarchy, creates a protected backup,
  and then directs the update inside the guest.
- A recovery path leads out of the error screen. A VM must actually stop before
  restoration is enabled; a paused guest can fall back to stopping when graceful
  shutdown is unavailable.
- Recovery progress, dated recovery points, completion messages, and clearer
  restore consequences.
- An app update download link and an updates and recovery guide.

### Validation

66 native tests passed; 389 core tests with one skipped and no failures; 12 CLI
tests passed. A disposable workspace completed protected snapshot creation,
simulated modification, and restoration with matching content hashes.

This release does not claim new validation of physical display hot-plug, real
host sleep and wake, or rapid post-commit input-method editing. Factory-image
installation creates a new workspace; it does not migrate an existing guest.

See [Updates and recovery](UPDATES_AND_RECOVERY.md).

## Earlier releases

The maintained notes below cover 0.1.11 and later. Notes for 0.1.0 through 0.1.10
remain only on [GitHub Releases](https://github.com/riftvm/riftvm/releases).
