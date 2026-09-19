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

## Factory signing keys

Creating an Omarchy workspace fetches a signed Factory manifest and verifies it
against the public keys compiled into the app
(`RiftVMOmarchyFactoryPublicKeysBase64` in `RiftVM/RiftVM/Info.plist`). A
manifest signed by any other key is rejected as `invalidSignature`, and that
rejection is a hard failure of workspace creation — every other release check
still passes while no user can create the featured workspace.

Two rules follow.

1. **Add a signing key to the app before signing a release with it.** The value
   is a set, so a rotation is: ship a build that accepts both the old and the
   new key, then start signing with the new one.
2. **Check the pinned manifest before publishing.** `publish-release.sh` runs
   `scripts/verify-factory-trust.sh` against the built app, and that script
   fails the release when the manifest the app will fetch verifies against none
   of its keys.

The script is also the quickest local check after touching a key or the manifest
URL:

```sh
scripts/verify-factory-trust.sh /Applications/RiftVM.app
```

It reads the manifest URL out of `VMOmarchyProfile.swift` and the trust anchors
out of the app, so neither can drift from what the check exercises.

## 0.4.0

RiftVM 0.4.0 shares more than one Mac folder with Omarchy, starting with
`~/riftvm-shared`, and creates new machines from factory
[v4.0.3-riftvm.13](https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/tag/v4.0.3-riftvm.13),
which adds the build tools developers expect.

Requires **macOS 27 or later and Apple silicon**.

### New

- **Shared folders.**
  - A new machine shares `~/riftvm-shared`. **Change…** on the Prepare screen
    picks another folder.
  - **Shared Folders…** in the window adds more folders, makes one read-only,
    or stops sharing one. Its files stay on the Mac.
  - Omarchy sees each folder at `/mnt/riftvm-shared/<name>`. Changes take effect
    the next time Omarchy starts, so programs running in a shared folder keep
    working. The sheet offers **Restart Omarchy**.
  - The clipboard no longer depends on a shared folder: it keeps working with
    every folder removed or read-only.
- **`make`, `patch` and the rest of `base-devel`** are installed in factory
  `.13`. A developer pass found them missing, so C builds, patches and most AUR
  packages needed a manual install first.
- **A way back to macOS.** While Omarchy has focus, Command shortcuts belong to
  Omarchy. A short hint when Omarchy starts, the Integration menu and the
  README now say that Control-Option frees the pointer for the Dock and the
  menu bar.

### Validation

A scripted developer day on fresh `.12` and `.13` machines ran:

- Git, including merges, conflicts, rebase, worktrees, and clones from GitHub.
- Neovim and VS Code editing.
- A frontend stack: Vite, React and TypeScript, HMR, Vitest, ESLint, pnpm, bun,
  Tailwind, Playwright, and Next.js.
- Python with uv, Go, Rust, and Docker Compose with PostgreSQL.
- Installing and removing packages with pacman and yay.
- Omarchy's shortcuts, with Command as Super.

Every product step passed on `.13`. The shared-folder layout, read-only
folders, deferred changes, the move of an existing folder, and the clipboard
were checked on both a new and an upgraded machine. Details are in the
[validation record](validation/v0.4.0-developer-day-2026-09-19/README.md).

### Upgrading an existing Omarchy machine

- Your folder moves from `~/.riftvm/RiftVM Shared` to `~/riftvm-shared` when
  that name is free; otherwise RiftVM keeps sharing the old folder.
- Omarchy keeps seeing it at `/mnt/riftvm-shared` until you install the `.13`
  integration package. After that, it appears at
  `/mnt/riftvm-shared/<folder name>` next to any folders you add. See
  [Updates and recovery](UPDATES_AND_RECOVERY.md#update-riftvm-integration-inside-an-existing-guest).

Install or update with Homebrew:

```sh
brew install --cask riftvm/tap/riftvm
brew upgrade --cask riftvm
```

Or download the app archive below.

## 0.3.3

RiftVM 0.3.3 creates new Omarchy machines from factory
[v4.0.3-riftvm.12](https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/tag/v4.0.3-riftvm.12),
which removes a `~/Mac` folder that looked like a Mac share but could not be
written to.

Requires **macOS 27 or later and Apple silicon**.

### Fixes

- **No more `~/Mac` that refuses writes.** Earlier images linked `~/Mac` to a
  host-folders mount RiftVM never provides. Opening it waited for a mount
  timeout, and `echo hello > ~/Mac/hello.txt` failed with "Permission denied".
  Factory `.12` drops the link and its units. The exchange folder is
  `/mnt/riftvm-shared`, which is RiftVM Shared on the Mac.

### Validation

- **Fresh `.12` machine:** `~/Mac` and its units are absent, the guest wrote a
  file to `/mnt/riftvm-shared` that appeared on the Mac, the wallpaper was
  present on first login, and the cursor-plane setting was in place.

### Upgrading an existing Omarchy machine

Existing machines keep their disk. Remove the stale link once inside Omarchy,
see [Updates and recovery](UPDATES_AND_RECOVERY.md#update-riftvm-integration-inside-an-existing-guest):

```sh
sudo systemctl --global disable riftvm-host-folders.service
sudo systemctl disable --now 'mnt-riftvm\x2dfolders.automount'
rm -f ~/Mac
```

Install or update with Homebrew:

```sh
brew install --cask riftvm/tap/riftvm
brew upgrade --cask riftvm
```

Or download the app archive below.

## 0.3.2

RiftVM 0.3.2 fixes web pages that use WebGL, such as YouTube, and the missing
wallpaper on a new machine's first login.

Requires **macOS 27 or later and Apple silicon**.

### Fixes

- **YouTube and other WebGL pages work in Chromium.** Pages drew without their
  icons and never finished loading, and after a restart the whole browser window
  could stay black. An antialiased WebGL canvas asks for multisample textures.
  RiftVM's renderer runs on Metal through ANGLE and cannot create them, and it
  used to reject them and stop the browser's entire GPU context. It now creates
  them single-sampled, so the page renders and loses only its antialiasing.
- **The wallpaper appears on the first login.** A new machine could start with
  its status bar but a plain background until the next boot. The display watcher
  in factory
  [v4.0.3-riftvm.11](https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/tag/v4.0.3-riftvm.11)
  now notices a blank desktop and has the Omarchy shell repaint the current
  wallpaper once, without restarting anything.

### Validation

- **YouTube and WebGL:** checked on a real Omarchy guest with the rebuilt
  renderer, using the Chromium profile that had turned black.
  - YouTube loaded with its logo and navigation icons, and a video played.
  - WebGL and WebGL2 created contexts, compiled shaders, drew and read back the
    expected colour in about 60 ms.
  - The host logged no rejected textures or failed contexts. Before the fix,
    every WebGL canvas produced a burst of them.
- **Wallpaper repaint:** on a machine that reproduced the bare first login,
  sending the watcher's repaint request brought the wallpaper back at once.
- **Fresh `.11` machine:** the wallpaper was present on first login.
  - The pointer was one cursor from the cursor plane: hidden while typing, back
    on the first mouse movement.

Not claimed: antialiasing in WebGL (it is off by design on this renderer),
hardware video decoding, and long browser sessions.

### Upgrading an existing Omarchy machine

The browser fix is in the app; update RiftVM and it applies at once. The
wallpaper fix is in the guest: new machines get it from factory `.11`, and
existing ones can install the `.11` integration package, see
[Updates and recovery](UPDATES_AND_RECOVERY.md#update-riftvm-integration-inside-an-existing-guest).

Install or update with Homebrew:

```sh
brew install --cask riftvm/tap/riftvm
brew upgrade --cask riftvm
```

Or download the app archive below.

## 0.3.1

<!-- draft: generated from commits; replace with user-facing wording if the change needs it -->

Requires **macOS 27 or later and Apple silicon**.

### Changes

- Stop linking the riftvm command into the Homebrew prefix — The tap's cask no longer links `riftvm` into /opt/homebrew/bin (riftvm/homebrew-tap 2bd157a).
- Sync checked-in cask with RiftVM 0.3.0 — Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>

### Fixes

- Centre Prepare Omarchy and resume a running preparation — The prepare screen ended in a bottom bar that repeated the caption above it and put the only action in the corner.

## 0.3.0

RiftVM 0.3.0 fixes the everyday Omarchy problems: the wallpaper disappearing,
clicks that did not register, and a second or lagging cursor.

Requires **macOS 27 or later and Apple silicon**.

### Fixes

- **One cursor, no lag.** Hyprland now uses virtio-gpu's cursor plane, and
  RiftVM shows the guest's cursor image (arrow, I-beam, resize arrows) as the
  macOS cursor at the true pointer position. Linux hid that plane from
  Hyprland, so the guest painted its own pointer into every frame; that was
  the second, trailing cursor. New machines get this from factory
  [v4.0.3-riftvm.10](https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/tag/v4.0.3-riftvm.10);
  existing machines need a one-time setting (see Upgrading).
- **The wallpaper stays.** The guest keeps the display mode it booted with for
  the whole session. RiftVM used to re-announce the mode whenever the guest
  agent reconnected, and each announcement made Hyprland rebuild its outputs
  and sometimes drop the wallpaper layer. Leaving full screen or resizing the
  window now only scales the picture.
- **Clicks register.** Mouse buttons go to the pointer device that last moved,
  so clicks are no longer lost while the pointer is captured. A key or button
  pressed while the agent reconnects is released on the same device, so it
  can no longer stay stuck.
- **Smoother pointer under load.** Queued mouse motion is merged instead of
  replayed, so the pointer no longer falls behind a busy guest.
- **Caps Lock works as Omarchy's Compose key on every press**, not every other
  press.
- **Scrolling.** Trackpad scrolling moves at a comfortable speed, and
  horizontal scrolling works with the .10 agent.
- **No flicker from reused buffers.** GPU fence completions now reach the
  guest in the order it submitted them, so it no longer reuses a buffer the
  GPU is still drawing into.

### Changes

- Custom VirGL is the only graphics backend, and RiftVM has one window for the
  one Omarchy machine.
- **Omarchy ▾ → Save Diagnostics…** saves the last 12 hours of RiftVM's
  display, cursor and input log for a bug report. These messages are now kept
  in the persistent log.

### Validation

A fresh machine was created from the signed `.10` factory and checked on real
hardware, without manual guest changes:

- 200 of 200 clicks arrived, plus right and middle clicks.
- 399 bytes of typed mixed-case text and symbols arrived byte-identical.
- Caps as Compose worked twice in a row.
- 200 points of trackpad scrolling gave 20 wheel steps; horizontal
  scrolling worked.
- One cursor with the guest's shape and no cursor painted into the frame, after
  boot and after two reboots.
- The guest stayed at 1920x1080 through full-screen and window changes, with
  the wallpaper intact.
- 60 fps with no presentation failures or fence timeouts under a 60-second
  redraw load.
- Clipboard worked in both directions, and pause/resume worked.

The record is in
[docs/validation/v1-real-guest-2026-09-18](validation/v1-real-guest-2026-09-18/README.md).
Not claimed: Command shortcuts, key repeat, real Mac sleep and wake, or
sessions longer than a few minutes of load.

### Upgrading an existing Omarchy machine

The .10 integration package updates the agent and display watcher, and one
command adds the cursor-plane setting; see
[Updates and recovery](UPDATES_AND_RECOVERY.md#update-riftvm-integration-inside-an-existing-guest).
Without the setting, an existing machine still shows two cursors.

### Known issues

- The guest's resolution is the Mac screen's size in points, so text on a
  Retina display is not as sharp as native macOS text.

Install or update with Homebrew:

```sh
brew install --cask riftvm/tap/riftvm
brew upgrade --cask riftvm
```

Or download the app archive below.

## 0.2.0

RiftVM 0.2.0 prepares Omarchy and nothing else, and gives the guest one display
mode per session so the desktop stops rebuilding itself.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- **RiftVM only prepares Omarchy workspaces.** The create flow no longer offers a
  second system: the macOS restore-image download, its version list, and its
  first-boot provisioning form are gone, the Ubuntu/Debian/Fedora ISO catalog is
  gone, and the local-image, remote-URL, and cached-image paths are gone with
  them. A workspace is one thing — the signed Omarchy factory image — and the
  preparation window is a name, the resources, and **Create Omarchy**.
- **One action starts everything.** The control center opens on a single
  **Prepare Omarchy** card, with the same action in the toolbar and the menu bar.
  The All/Running/Omarchy/macOS sidebar and its counts are gone; the window is
  the workspace grid and the preparation banner.
- **A workspace is an independent Arch Linux machine.** Start, pause, resume,
  stop, snapshots, rename, and move-to-trash are unchanged, and Pause, Resume,
  and Stop are now on the workspace card as well as in the workspace window and
  the menu bar. Dropping files on a card still copies them into RiftVM Shared.
- **Workspace windows open full screen, and the guest keeps one display mode.**
  The scanout is the screen the window is on, the host scales it into the window,
  and a resize or a full-screen transition costs host-side scaling only — it no
  longer re-publishes a mode and rebuilds the guest's outputs. **Graphics → Fit
  Display to Window** re-offers the guest the window's current size and holds it;
  **Graphics → Use Screen Size** returns to the screen canvas, and entering full
  screen does too.
- The workspace registry no longer records a guest kind. Existing records load
  unchanged, and the `kind` field is simply no longer written.

### Fixes

- **The desktop no longer flickers, and the wallpaper no longer disappears on a
  display-mode change.** Every size that reached the guest's DRM rebuilt its
  outputs: the desktop flashed, the background layer lost its committed buffer,
  and the bar could go with it. With one mode per session that path is not
  reached. (The 0.1.29 guest-side repair remains in the current factory image for
  workspaces that change mode for another reason.)

### Validation

- The app builds and the shared core suite passes (425 tests, 1 skipped), the
  Omarchy integration test bundle builds, and the CLI suite passes.
- The release pipeline runs the signing, notarization, staple, entitlement,
  visible-window, and factory-trust checks, plus a real preinstalled-image import
  and boot smoke test.
- Not claimed: flicker is only reported fixed by the 0.2.0 display rule on the
  Macs that reported it; sleep/wake, external displays with different scales, and
  the guest input defect below are not part of this release's checks.

### Known issues

- An intermittent guest input defect remains open: shortly after pausing and
  resuming, typed characters can repeat or a line can be lost.
- Workspaces created from an image older than `v4.0.3-riftvm.9` do not carry the
  display watcher. New workspaces use the current factory image; update an
  existing Guest with the paired integration package (see
  [Updates and recovery](UPDATES_AND_RECOVERY.md)).

Install or update with Homebrew:

```sh
brew install --cask riftvm/tap/riftvm
brew upgrade --cask riftvm
```

Or download the app archive below.

## 0.1.29

RiftVM 0.1.29 keeps the Omarchy wallpaper through a display mode change and
replaces the workspace-creation animation with a progress meter.

Requires **macOS 27 or later and Apple silicon**.

### Features

- **Workspace creation shows a live progress meter instead of the lightning
  rift.** The rift pulled the eye to the middle of the window and read as a light
  smudge rather than a state. One row of vertical blocks now carries the progress:
  the lit blocks are the bytes already transferred, the block at the frontier
  bounces hardest, the blocks behind it settle, and the finished row is held for
  a beat before the ready icon takes its place. Heights come from a pure
  `(index, progress, time)` function, so a paused window, Reduce Motion, and a
  screenshot all render the same frame, and the meter stays out of the
  accessibility tree while the existing progress text keeps reporting the value.
- **The preparation screen is tightened around the meter.** The stage and the
  transferred bytes share one line inside a progress card, the status is centred
  in the window instead of hugging its top, and **Continue in Background** is now
  the prominent action for a long download.

### Fixes

- **The Omarchy desktop keeps its wallpaper when the display mode changes.** A
  virtio-gpu mode change replaces the compositor's output surfaces, and Omarchy's
  background layer can come back without its committed buffer. The wallpaper is
  static, so nothing redrew it by itself: the bar and the dock stayed, the desktop
  behind them went bare, and it returned only when an unrelated window resize
  forced a repaint or the shell restarting did. Omarchy cannot repair that from
  inside, because its own background IPC deliberately does nothing while the
  wallpaper path is unchanged. The display watcher now re-applies the active theme
  through the one IPC entry point that forces a repaint, once the compositor
  confirms a new mode: the desktop repaints itself, and the appearance is
  unchanged.

### Changes

- New Omarchy workspaces are created from factory image `v4.0.3-riftvm.9`, which
  carries the display watcher described above. Workspaces created from earlier
  images keep working; update an existing Guest with the paired integration
  package to get the fix there (see
  [Updates and recovery](UPDATES_AND_RECOVERY.md)).

### Validation

- The image contract suite drives the watcher against a fake compositor and a fake
  shell IPC and asserts the exact repaint payload, exactly one repaint for a
  settled mode change, and no repaint while the mode is unchanged.
- The app test suite (426 core tests with 1 skipped, plus 16 CLI tests), the Guest
  Agent tests, the Release build, the factory trust check, and the
  preinstalled-image smoke test run as part of this release.
- Not claimed: live first-boot wallpaper retention observed on hardware other than
  the Mac that reported the issue, and 3D or sleep/wake behaviour this release
  does not touch.

## 0.1.28

RiftVM 0.1.28 fixes workspace removal, the doubled cursor on the Omarchy desktop,
and the workspace card layout.

Requires **macOS 27 or later and Apple silicon**.

### Fixes

- **A workspace whose folder was deleted outside RiftVM can be removed from the
  list.** The registry and the disk can disagree — the workspace folder may have
  been deleted in Finder, or wiped when Application Support was reset — and
  "Move to Trash" then failed with `The file “Omarchy.riftvm” doesn't exist.`
  before the registry record was removed. The card stayed in the list and every
  attempt failed the same way, so the only way out was editing
  `WorkspaceRegistry.json` by hand. A missing folder now removes the record
  instead; the menu and the confirmation dialog say "Remove from List" and
  explain that there is nothing left to trash.
- **A workspace that is still on disk behaves as before.** The bundle is moved
  to the Trash first, and a failure to do so (a locked volume, a permission
  problem) still reports the error and keeps the entry, so a workspace is never
  dropped from the list while its files are still there.
- **A desktop that paints its own cursor no longer shows two of them.** Absolute
  pointer mode keeps the macOS cursor as the pointer and hides the image the app
  composites from virtio-gpu's cursor plane. A guest compositor that falls back
  to software cursors draws its cursor into the frame instead, where it cannot be
  hidden separately, so the macOS cursor and the guest's own overlapped. The app
  now yields the system cursor to a cursor the guest painted into its own frames,
  and takes it back as soon as the guest drives the cursor plane.
- **Absolute pointer input is claimed only when the running desktop uses it.**
  The agent advertised `input-uinput-absolute-v1` whenever the uinput device
  existed, and the app switches to absolute pointer events on that capability. A
  device node is not evidence that anything reads it: with the wrong udev class
  libinput drops the node, so absolute events were written where nothing
  consumed them and the cursor never moved while the wheel kept working. The
  agent now also requires the compositor to hold the device's event node, so a
  guest in that state degrades to the relative pointer instead of a frozen
  cursor.

### Changes

- New Omarchy workspaces are created from factory image `v4.0.3-riftvm.8`, which
  classifies the `RiftVM Absolute Pointer` device as the absolute mouse it is and
  carries the Agent that gates absolute pointer input on the live desktop. The
  previous factory left the cursor frozen because the misclassified device never
  reached the compositor.
- The workspace card anchors its Open/Start button to the card's bottom edge.
  Cards keep a minimum height so a grid row lines up, and the leftover space used
  to collect below the button.

### Validation

- 419 `RiftVMCoreTests` and 16 `RiftVMCLIKitTests` cases passed with 0 failures
  and one existing conditional skip, including three new
  `RiftWorkspaceBundleRemovalTests` cases and six new
  `VMDisplayCursorPolicyTests` cases. The Go Guest Agent suite passed, and the
  Linux arm64 Agent cross-build succeeded.
- The `RiftVM` app target and the `RiftVMIntegrationTests` target both built with
  the released Xcode 27.0 (27A266a).

This release does not change workspaces created from an earlier factory image:
they keep their disks, and an existing workspace gains the corrected pointer class
only from the paired image release or from applying the same one-line correction
inside the guest. The cursor change is covered by unit tests and a build, not by
a booted guest in this release's own validation. This release does not re-run the
macOS restore-image acceptance, physical display hot-plug, real Host sleep, or
120 Hz latency work; those remain open in [TODO](TODO.md).

## 0.1.27

RiftVM 0.1.27 makes the command line able to see the workspaces the app creates.

Requires **macOS 27 or later and Apple silicon**.

### Fixes

- `riftvm list` and `riftvm inspect` now find Omarchy workspaces. Discovery only
  looked for `config.json` in a bundle root, while an Omarchy workspace keeps its
  configuration, guest disk and machine identity under `Workspace/`, so the
  command reported an empty list on a Mac that had the featured workspace
  installed.
- `riftvm start`, `status` and `stop` no longer describe a healthy Omarchy
  workspace as `config.json is missing or invalid JSON`. Those commands drive
  general machines only, because an Omarchy workspace needs the guest agent and
  the Omarchy machine builder that the headless path does not provide; they now
  exit 69 with `unsupported_layout` and point at the app.

### Validation

- Four new `RiftVMCLIKitTests` cases cover both layouts: a workspace listed
  beside a general machine, an inspected workspace descriptor, a missing
  workspace disk, and the lifecycle rejection. The suite is 16 cases with no
  failures.
- Checked against a real workspace on disk, not only fixtures: `riftvm list`
  reports `Omarchy.riftvm` as a valid `linux` machine with its CPU and memory,
  and the lifecycle commands return `unsupported_layout`.

This release does not change the app, the guest agent, or the Omarchy factory
image.

## 0.1.26

RiftVM 0.1.26 fixes Omarchy workspace creation, which every build since 0.1.18
rejected, and redraws the seam shown while a workspace is prepared.

Requires **macOS 27 or later and Apple silicon**.

### Fixes

- **Creating an Omarchy workspace works again.** RiftVM pins a signed Factory
  manifest and refuses one whose signature it cannot verify. The factory signing
  key rotated, and the published `.6` and `.7` images are signed with a key the
  app did not carry, so creation stopped right after "Fetching the signed
  Omarchy Factory manifest" with `VMOmarchyFactoryValidationError` (error 3).
  The app now carries a set of signing keys and accepts a manifest signed by any
  of them, so images signed before or after a rotation both verify. Existing
  workspaces were never affected: the manifest is only checked when one is
  created.
- A failed creation no longer leaves a frozen fragment of the animation in the
  middle of the window. The error screen shows the explanation alone.

### Changes

- The seam shown while a workspace is prepared is redrawn. Its colour gradient
  was laid out across the container instead of across the tear, so the warm and
  cool lips never appeared and the shape read as a thin blurred sliver. It is
  now an irregular tear with light bent along its lips and matter falling into
  it, and it pulls back to a slit once the workspace is ready so the icon stays
  legible.

### Validation

- The pinned Factory manifest was fetched and verified against the keys inside
  the built app, and a manifest edited after signing is still rejected. The
  release runs this check before publishing, so an image the app cannot verify
  can no longer ship.
- 422 Swift tests passed with 0 failures and one existing conditional skip
  (410 in `RiftVMCoreTests`, 12 in `RiftVMCLIKitTests`). Go Guest Agent tests
  passed, and the Linux arm64 Guest Agent cross-build succeeded. The Linux image
  catalog contract test verified all four images and rejected drift.
- Against the shipped build and the signed `v4.0.3-riftvm.7` image:
  preinstalled-image import, validation, boot, status, and clean stop; CLI JSON,
  concurrent machines, SIGKILL restart, saved-state fallback, and EFI boot
  recovery; guest boot with Guest Agent authentication and an upload/download
  byte round-trip; and nested virtualization with guest `/dev/kvm`.
- macOS restore-image acceptance, physical display hot-plug, real Host sleep,
  and 120 Hz latency work are not re-run; they remain open in [TODO](TODO.md).

## 0.1.25

RiftVM 0.1.25 rebuilds the 0.1.23 source with the released Xcode 27 toolchain.
The application code is unchanged.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- The archive is built with the released Xcode 27.0 (27A266a). No source,
  entitlement, or behaviour change is included.
- Repository changes carried in this release are documentation and website only:
  GitHub issue templates, the website palette and copy, and the checked-in
  Homebrew cask.

There is no integration-package update in this release. Workspaces, images, and
the Omarchy Agent and display watcher are identical to 0.1.23, so existing
Guests need no integration install or reboot.

### Validation

418 Swift tests passed with 0 failures and one existing conditional skip
(406 in `RiftVMCoreTests`, 12 in `RiftVMCLIKitTests`). Go Guest Agent tests
passed, and the Linux arm64 Guest Agent cross-build succeeded. The Linux image
catalog contract test verified all four images against the served, source, and
built-in copies and rejected drift. A clean Release build for
`platform=macOS,arch=arm64` succeeded with the released Xcode 27.0 (27A266a).

Before the release is published, the archive is also signed with Developer ID,
notarized, stapled, Gatekeeper-assessed, and checked for a visible main window.

The runtime gates ran against the shipped build and the signed
`v4.0.3-riftvm.7` preinstalled image, which was verified part by part and as a
whole before use:

- Preinstalled-image manifest check, import, validation, boot, status, and clean
  stop.
- CLI JSON, concurrent machines, SIGKILL restart, saved-state fallback, and EFI
  boot recovery.
- Guest boot, Guest Agent authentication, upload/download byte round-trip, and
  clean stop.
- Nested virtualization: guest `/dev/kvm` with `KVM_GET_API_VERSION=12`.

This release does not re-run the macOS restore-image acceptance, physical
display hot-plug, real Host sleep, or 120 Hz latency work; those remain open in
[TODO](TODO.md).

## 0.1.23

### Performance

- New Omarchy workspaces use factory `.7`, which reduces idle display watcher
  compositor queries by 90% while retaining one-second DRM resize detection and
  fast retries for unconfirmed changes. This is a query-frequency improvement;
  CPU and energy savings have not been quantified.
- Existing Guests can install the paired `.7` integration update, preserving
  configuration and retaining rollback. Reboot the Guest to activate it.

### Validation

- Real Guest mode repair, cold start, clipboard/file integration, resize and six
  cross-display focus cycles passed with VFR enabled.
- See [watcher validation](validation/watcher-idle-2026-09-13/README.md) and
  [upgrade instructions](UPDATES_AND_RECOVERY.md).

## 0.1.22

RiftVM 0.1.22 connects new Omarchy workspaces to the demand-rendering factory and
provides an explicit integration upgrade for existing Guests.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- New workspaces use signed factory `v4.0.3-riftvm.6`, built in full with the
  matching Agent and display watcher. Both stop overriding Hyprland VFR.
- Existing Guests can install the paired integration package linked in
  [Updates and recovery](UPDATES_AND_RECOVERY.md). It backs up both components,
  preserves pairing and user configuration, and supports rollback. A reboot
  activates the update; the app does not automatically replace existing disks.

### Validation

The full ARM64 image build and eight transactional updater tests passed. A
previous-factory component baseline was upgraded in a disposable Guest, rebooted,
checked for service readiness and keyboard-only final updates, rolled back to the
original file hashes, and booted again. Pairing configuration remained unchanged.
See [delivery evidence](validation/omarchy-integration-delivery-2026-09-13/README.md)
for signed factory qualification, exact sources and limits.

Physical display hot-plug, real Host sleep, complex 3D compatibility and longer
energy measurements remain [TODO](TODO.md). Custom VirGL GPU memory-state
save/restore remains unsupported; Omarchy uses disk recovery points.

## 0.1.21

RiftVM 0.1.21 presents Omarchy frames on demand while retaining the last pending
update when rendering is busy.

Requires **macOS 27 or later and Apple silicon**.

### Performance

- Normal Host presentation no longer runs a repeating 60 Hz timer. Pending updates
  are coalesced and drained on completion; failed presentations get bounded retries.
- Visibility restoration and geometry changes request a fresh frame.
- Rift Agent no longer forces Hyprland variable frame rendering off.

### Validation and rollout

Six core timing/demand tests and 66 native Omarchy integration tests passed, along
with Go tests and Release build checks. Temporary Guest checks covered keyboard-only
final updates, minimize/restore, pause/resume input, clipboard/files, resize, and
six display/focus cycles. See [the report](validation/omarchy-demand-rendering-2026-09-13/README.md).

The complete idle improvement requires the updated Agent and image display watcher
inside the Guest. This app patch does not publish a new factory or migrate existing
Guest disks; existing installations can retain their continuous-rendering override.
Fresh signed factory qualification, complex 3D, physical hot-plug and real Host
sleep/wake remain in [TODO](TODO.md). The short idle sample is not a universal
speedup or power-saving claim. Custom VirGL GPU memory-state save/restore remains
unsupported; Omarchy uses disk recovery points.

## 0.1.20

RiftVM 0.1.20 improves Omarchy responsiveness and reduces host graphics overhead.

Requires **macOS 27 or later and Apple silicon**.

### Performance

- Socket backpressure and Metal drawable waits run off the main thread, keeping
  host input and window events responsive while the guest or display catches up.
- Hidden, minimized, and fully occluded windows stop host presentation and resume
  with the latest guest frame. Stale display work is discarded after visibility changes.
- VirGL submits aligned command buffers without redundant copies, tracks active
  synchronization contexts, and handles renderer queue backlogs more efficiently.
- Diagnostics now include drawable wait and full-frame CPU timing alongside the
  existing render-only metrics.

### Validation

511 tests passed, with one opt-in near-full APFS volume test skipped. C context
lifecycle sanitizer tests and the Release build also passed. Temporary Omarchy
checks covered two displays, resize/focus recovery, text and PNG clipboard round
trips, file sharing, minimize/restore, and pause/resume input.

Visible and restored desktop samples sustained 60 FPS with no drawable misses or
presentation failures; the worst window full-frame P95 was 16.45 ms. This is not
an old/new binary A/B comparison or a new complex 3D benchmark. No new host
lock/sleep qualification is claimed. GPU memory-state save/restore remains
unsupported for Custom VirGL; Omarchy uses disk recovery points.

See [the validation report and raw evidence](validation/performance-display-queue-2026-09-13/README.md).

## 0.1.19

RiftVM 0.1.19 adds per-workspace graphics selection and protects backend changes
while a virtual machine is running.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- Linux graphics are configured in **Settings → Display → Graphics Backend**.
  Omarchy defaults to **Custom VirGL**; **Apple Virtio** is an explicit
  compatibility option. Existing Omarchy workspaces retain the Custom VirGL default.
- macOS always uses **Apple Graphics**. Display device types follow the guest OS.
- Graphics choices persist with the VM. Switching requires shutdown; saved machine
  state must first be resumed and shut down, or discarded. Startup failures never
  silently select another backend.
- Custom VirGL on other Linux guests requires compatible drivers and an enrolled
  Guest Agent. Generic installation fixtures and new CLI image imports use Apple
  Virtio for setup; users can select Custom VirGL after guest integration is ready.
- Omarchy now participates in the shared running registry, including startup,
  pause, shutdown, and asynchronous teardown. Running workspaces are correctly
  labeled, and settings cannot race a VM startup in another process.
- The old global graphics preference is replaced by per-VM settings. README,
  website, architecture, and troubleshooting guidance describe the new behavior.

### Validation

- Core and CLI regression coverage includes metadata compatibility, explicit
  native graphics, refusal to fall back, saved-state restrictions, and exclusive
  settings/startup leases.
- Disposable Omarchy workspace verification covers both backends, login and
  terminal input, a short real 3D workload, settings persistence, and switching
  after shutdown. No lock or sleep tests are performed.

## 0.1.18

RiftVM 0.1.18 brings hardware-accelerated Custom VirGL graphics to the dedicated
Omarchy workspace flow.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- Omarchy now uses Custom VirGL exclusively: Guest Mesa VirGL commands are
  rendered through ANGLE on Metal. Missing runtime libraries produce a clear
  startup error instead of silently selecting Apple Virtio graphics.
- Authenticated input works at login and on the desktop. Native setup and pause
  overlays release held input, and returning to the desktop restores keyboard
  focus without an extra click.
- Window and fullscreen changes negotiate Guest resolution through Custom
  VirGL. Redundant delayed refreshes no longer postpone mode changes.
- GPU resources remain alive until the virtual machine has stopped. Startup
  failures before VM creation still allow Stop and Enable Recovery.
- README, website source, and graphics troubleshooting now describe this path.

### Validation

Real Guest output reports VirGL and the host reports ANGLE Metal. Three repeated
1280×720 glmark2 GLES 2 runs compared the same temporary Guest against the former
Apple Virtio path, which reported llvmpipe. Median speed ratios were 2.62× for
Phong shading, 45.48× for terrain, and 19.39× for refraction. The simple model
scene was slightly slower (0.97×). Desktop scale differed between paths; these
are workload-specific product-path results, not universal speedup claims.
See [the full method and raw results](validation/omarchy-custom-virgl-2026-09-13/README.md).

Temporary workspace checks covered first owner setup, login, pause/resume,
restart, protected backup/restore, text and PNG clipboard round trips, shared
files, and six display/focus cycles across two monitors. Fault injection verified
missing-runtime failure without fallback and a working recovery entry point.
Targeted Core and native integration regression tests passed, as did the normal
Release build and production test-isolation check.

No new lock/sleep or physical hot-plug qualification is claimed. Custom VirGL
provides GLES 3.0 in this tested Guest; this release does not claim Vulkan or
universal game/application compatibility. GPU memory-state save/restore remains
unsupported; Omarchy uses disk recovery points.

## 0.1.17

RiftVM 0.1.17 delivers the refreshed Omarchy factory and waits for asynchronous
forced shutdown before allowing the app to quit.

Requires **macOS 27 or later and Apple silicon**.

### Changes

- New Omarchy workspaces use signed factory `v4.0.3-riftvm.5`, with responsive
  Guest Agent input dispatch and a first-run update notice only when updates are
  available. Existing guest disks are retained.
- Quit waits for forced shutdown completion. If even forced shutdown stalls,
  RiftVM cancels Quit and explains why it stayed open instead of killing the
  guest through process teardown.
- CI now executes the Core regression suite. Resource tests respect the real
  framework limits of smaller runners.
- Update/recovery documentation separates current status from historical failures
  and explains repository download failures.

### Validation

Thirteen quit/close policy tests passed. Core tests ran 392 cases with one skip
and zero failures. Real temporary Omarchy checks covered close/cancel, paused
close, one-Guest quit and a two-Guest app quit (one guest awaiting owner setup).
The two-Guest check confirms app exit; it does not measure each framework stop
callback independently.

The signed factory passed raw-to-ASIF byte comparison, trusted signature checks,
remote multipart digest verification, and fresh owner setup. A real update
upgraded 37 packages, rebooted successfully, and was then restored through the
protected recovery point. Restored disk hash and package inventory matched;
the pre-update marker survived and the later marker was removed. The restored
system booted and displayed terminal input normally.

No new host lock/sleep, physical hot-plug, or macOS saved-state qualification is
claimed. The first update attempt encountered repository timeouts; the retry
succeeded without changing mirrors or bypassing signature checks.

## 0.1.16

**Status update, September 12:** The pause/resume input issue listed in this
release's original known issues was subsequently closed after the maintainer's
re-check. See [current validation status](P0_VALIDATION.md). The original release
record below is preserved; this update does not claim a new automated run.

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
