# Release notes

RiftVM publishes one GitHub release per `riftvm-vX.Y.Z` tag. This file is the
in-repository record of what each release contains, and the convention that
keeps new notes consistent.

## Where notes live

- **GitHub Releases** is what users read: the note body is set from a written
  file at publish time, not from `--generate-notes`.
- **This file** keeps the same note, versioned with the source, so the reason
  for a release stays reviewable after the tag.

`scripts/release-notes.sh` keeps the two in step:

- `prepare <version>` adds a draft section when a release has none. The release
  scripts call it, so a missing note never blocks a release; a section that
  already exists is never touched.
- `extract <version>` prints the note as the GitHub release body, with links made
  absolute. `publish-release.sh` calls it, so the published body comes from this
  file instead of `--generate-notes`.
- `check` reports releases without a section for manual use.

A draft lists the commits between the previous release and this one as a
starting point. Replace it with a real note before publishing; a draft that is
still in place ships as-is, which is better than an empty note but not good.

## How to write a release note

1. Start from the commits between the previous tag and the new one
   (`git log --oneline riftvm-v0.1.13..riftvm-v0.1.14`). Ignore version
   preparation commits.
2. Describe **what changed for a user and why**. Commit subjects are not release
   notes: `Fix null check in catalog` says nothing; "the app asked a retired host
   that answered 404, so the list never refreshed" does.
3. Keep it short. Only list changes a user of this build can observe or rely on.
   Internal refactors and evidence-recording commits do not belong here.
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

### Changes

- <user-visible change and its motivation>

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
