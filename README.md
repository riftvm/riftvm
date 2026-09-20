<p align="center">
  <img src="./Assets/RiftVM-mark.png" width="160" height="160" alt="RiftVM red and blue rift R icon">
</p>

# RiftVM

**Omarchy Linux on your Mac, full screen and GPU-accelerated — a focused native app for macOS 27 on Apple silicon.**

[![macOS 27+](https://img.shields.io/badge/macOS-27%2B-111827?logo=apple)](https://support.apple.com/macos)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-111827)](https://support.apple.com/en-us/116943)
[![License](https://img.shields.io/github/license/riftvm/riftvm)](LICENSE)

## Install RiftVM

On an Apple silicon Mac running **macOS 27 or later**, install the signed
and notarized app with Homebrew:

```bash
brew install --cask riftvm/tap/riftvm
```

RiftVM prepares **an Omarchy machine**: a focused Arch Linux desktop in a real
virtual machine, created from a signed and verified factory image and running
locally through Apple's
[Virtualization.framework](https://developer.apple.com/documentation/virtualization).
Omarchy is the one machine RiftVM prepares, so the whole app is arranged
around it.

Prefer a direct download? Get the signed and notarized app from
[GitHub Releases](https://github.com/riftvm/riftvm/releases/latest).

## Prepare Omarchy

1. Open RiftVM. The app has one window: it shows the **Prepare Omarchy** form
   until Omarchy exists, and shows Omarchy afterwards.
2. Adjust the disk location and resources. The disk defaults to the hidden
   `~/.riftvm/Omarchy.riftvm` path, so it does not sit in your visible home
   folder; choose **Change…** to pick another location, and RiftVM remembers it.
   There is no name to choose: the machine is always Omarchy.
3. Click **Prepare Omarchy**. RiftVM downloads the factory image, verifies its
   signed manifest and its digest, and creates the machine. The window then
   shows **Omarchy is stopped**: press **▶ Start Omarchy**, and the window takes
   the screen while the guest runs. Omarchy guides you through owner setup on
   first boot.

The machine has its own writable disk and machine identity. The verified
factory image is cached for reuse; preparing Omarchy still needs a connection
to fetch and verify the signed release manifest. The guest keeps one display mode
per session, chosen from the screen before it boots, and the window goes full
screen while it runs. Resizing the window scales the desktop; it never changes
the guest's mode.

## What it does

- Runs Omarchy locally through Apple's native virtualization stack
- Creates Omarchy from a signed, verified factory image with guided owner setup
- Starts, pauses, resumes, and stops Omarchy from its window or the menu bar
- Reuses the verified image and gives the machine its own writable disk and machine identity
- Integrates Omarchy keyboard shortcuts, text and image clipboard exchange, and notifications through an authenticated guest agent
- Shares Mac folders with Omarchy: `~/riftvm-shared` by default, chosen on the Prepare screen, and more from **Shared Folders…**, each read-write or read-only. Omarchy sees each one under `/mnt/riftvm-shared/<name>` from its next start; **Open Shared Folder** and **Import Files** use the first writable one
- Creates protected Omarchy recovery points before updates and restores them while the guest is stopped
- Keeps one display mode per session, so resizing the window never rebuilds the
  guest's outputs, and opens full screen while the guest runs
- Takes stopped-machine snapshots and keeps checksum-verified `.riftvmexport`
  import/export
- Keeps Omarchy in the hidden `~/.riftvm` folder by default, with removal and
  snapshots inside the one window

### Keyboard and pointer

While Omarchy's window has focus, Command acts as Omarchy's Super key, so
Omarchy shortcuts such as Command-Return (terminal), Command-Space (menu),
Command-1…5 (workspaces) and Command-W (close window) work as documented by
Omarchy, and macOS shortcuts such as Command-Tab and Command-Space do not
leave the window. Press **Control-Option** to free the pointer, then use the
Dock or the menu bar (move to the top of the screen) to switch apps or reach
RiftVM's toolbar. Click the desktop to hand the pointer back to Omarchy.
Command-C and Command-V copy and paste inside Omarchy, and the clipboard is
shared with the Mac.

### Update and recover Omarchy

Use **Updates → Prepare for Omarchy Update…** to stop the guest and create a
protected recovery point. Start Omarchy and update it from its own menu. If the
update causes problems, stop it and restore the saved point from **Recovery**.

To try a newer signed channel image, open **Omarchy ▾ → Remove Omarchy…**. That
moves the existing machine and its data to the Trash and returns the window to
**Prepare Omarchy**, where you prepare again from the current signed factory
channel. There is no side-by-side copy, and updating RiftVM itself or downloading
a newer factory does not replace your guest disk. See [Updates and recovery](docs/UPDATES_AND_RECOVERY.md).

## Requirements

- An Apple silicon Mac
- macOS 27 or later
- A network connection when you prepare Omarchy, to fetch the signed image

## Limits to know

- Apple silicon and macOS 27 or later are required. Intel Macs are not supported, and RiftVM no longer prepares macOS guests or generic Linux ISO installations; Omarchy is the supported machine.
- Stop a machine before taking or restoring a file snapshot. Keep backups of important guests.
- Omarchy runs Custom VirGL graphics and uses disk recovery points. Use its Start/Stop and Recovery controls; GPU memory-state save/restore is not supported.
- Omarchy sees only the folders you share, `~/riftvm-shared` by default. Anything Omarchy can write, it can change or delete, so share other folders read-only unless you mean to edit them from Linux.
- Chinese input methods are installed and configured inside Omarchy by the user; Mac input-method passthrough is not provided. See [Chinese input](docs/OMARCHY_INPUT.md).

For setup, display, input, and signing problems, see the
[troubleshooting guide](docs/TROUBLESHOOTING.md).

### Command line

The `riftvm` command ships inside the app at
`/Applications/RiftVM.app/Contents/Helpers/riftvm` for diagnostics and scripting;
Homebrew does not add it to your `PATH`. Link it yourself if you want it there:

```sh
ln -s /Applications/RiftVM.app/Contents/Helpers/riftvm /opt/homebrew/bin/riftvm
riftvm list
riftvm inspect "Omarchy"
riftvm doctor
```

Every command writes one schema-versioned JSON object and uses deterministic
exit codes. `list`, `inspect`, `validate` and `doctor` report what is on the
Mac; starting and stopping Omarchy happens in the app.

## Build from source

1. Clone this repository.
2. Open `RiftVM/RiftVM.xcodeproj` in Xcode.
3. Select the **RiftVM** scheme and your Mac as the run destination.
4. Choose your own development team and bundle identifier if code signing requires it.
5. Build and run with <kbd>⌘R</kbd>.

See the [documentation index](docs/README.md) for troubleshooting, image formats,
guest integration, graphics architecture, and distribution details.

## How it works

RiftVM needs macOS 27 because it builds its own virtual GPU. macOS 27 adds
`VZCustomVirtioDevice` to Virtualization.framework, which lets an app implement
a standard virtio device itself. RiftVM implements **virtio-gpu** (device 16) on
it, so Omarchy's stock `virtio_gpu` driver and Mesa's VirGL driver work without
anything extra in the guest.

- **Custom VirGL.** Mesa encodes OpenGL calls as VirGL commands; RiftVM decodes
  them with virglrenderer and runs them through ANGLE on Metal. Scanout is
  zero-copy: the texture Hyprland presents is drawn straight into the window's
  Metal layer. Custom VirGL is the only graphics path; if the runtime cannot
  start, RiftVM reports the error instead of switching backends. Browsers get
  working WebGL, including pages that ask for multisampled buffers.
- **One cursor.** Omarchy hands its pointer image to the host through the
  virtio-gpu cursor commands, and RiftVM shows it as the macOS cursor. There is
  no second, lagging pointer painted into the frame.
- **Fixed display mode.** The guest mode is chosen from your screen before boot
  and stays the same for the session, so Hyprland never rebuilds its outputs and
  the wallpaper and bar stay put.
- **Guest agent.** An authenticated vsock agent delivers keyboard and pointer
  input through uinput, mirrors text and image clipboards, maps Command
  shortcuts to Super, forwards notifications, and completes first-boot owner
  setup.

GPU memory-state save/restore is not supported, because guest RAM alone cannot
reconstruct renderer contexts. Stopped-machine snapshots and Omarchy recovery
points protect the disk and configuration instead.

Details are in the [Custom VirGL architecture notes](docs/CUSTOM_VIRGL_ARCHITECTURE.md),
[performance guide](docs/VIRGL_PERFORMANCE.md), and the isolated
[prototype record](Experiments/VZVirtioGPUPrototype/README.md). If something
goes wrong, choose **Omarchy ▾ → Save Diagnostics…** and start with the
[troubleshooting guide](docs/TROUBLESHOOTING.md).

## Guest image

Choose **Prepare Omarchy**. RiftVM downloads the pinned Factory release, verifies
its signed manifest and image digest, creates a private writable disk and machine
identity, then guides you through owner setup. Generic Linux distributions,
custom ISO installation, and macOS guests are intentionally outside RiftVM's
product scope.

## Direction

RiftVM is not trying to replace UTM, VirtualBuddy, Tart, or Lima. It does one thing: run Omarchy well on a Mac.

1. Make preparing, starting, stopping, recovering, and reporting errors for Omarchy reliable, with a real-guest check before every release ([V1 release checklist](docs/V1_RELEASE_CHECKLIST.md)).
2. Keep local macOS 27 tests, signed releases, Homebrew distribution,
   diagnostics, and configuration migration reproducible. CI runs core, CLI,
   runtime, and build checks on the `xcode-27` runner, with Guest Agent checks on
   Ubuntu. Real VM, physical-display, and signed-release acceptance remain
   separate from build checks.
3. Keep everything local: RiftVM does not embed an AI model or require a cloud account.

See the [documentation index](docs/README.md) for maintained technical references.

## Contributing

Issues and focused pull requests are welcome. Reliability fixes, reproducible bug reports, tests, accessibility improvements, and documentation updates are especially useful.

When reporting a VM problem, include the host macOS version, Mac model/chip, Omarchy image version, and the last operation performed. **Omarchy ▾ → Save Diagnostics…** collects the host log; review it before attaching. Do not attach VM disks or logs containing secrets.

## Community

- [GitHub Issues](https://github.com/riftvm/riftvm/issues) for bugs, questions, and focused feature requests
- [Discord](https://discord.gg/eGzEaP6TzR) for informal conversation

## License

RiftVM is available under the [MIT License](LICENSE).
