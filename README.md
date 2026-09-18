<p align="center">
  <img src="./Assets/RiftVM-mark.png" width="160" height="160" alt="RiftVM red and blue rift R icon">
</p>

# RiftVM

**Virtual machines, made easy — a focused native app for Apple silicon Macs.**

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
per session and the window goes full screen while it runs; **Graphics → Fit
Display to Window** re-offers the guest the window's current size when you want a
different one.

## What it does

- Runs Omarchy locally through Apple's native virtualization stack
- Creates Omarchy from a signed, verified factory image with guided owner setup
- Starts, pauses, resumes, and stops Omarchy from its window or the menu bar
- Reuses the verified image and gives the machine its own writable disk and machine identity
- Integrates Omarchy keyboard shortcuts, dynamic display sizing, text and image clipboard exchange, and notifications through an authenticated guest agent
- Exchanges files through **Open Shared Folder** and **Import Files**; Omarchy sees its private exchange folder at `/mnt/riftvm-shared`
- Creates protected Omarchy recovery points before updates and restores them while the guest is stopped
- Keeps one display mode per session, so resizing the window never rebuilds the
  guest's outputs, and opens full screen while the guest runs
- Takes stopped-machine snapshots and keeps checksum-verified `.riftvmexport`
  import/export
- Keeps Omarchy in the hidden `~/.riftvm` folder by default, with removal and
  snapshots inside the one window

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
- Omarchy defaults to Custom VirGL graphics and uses disk recovery points. Use its Start/Stop and Recovery controls; GPU memory-state save/restore is not supported.
- Omarchy shares only its managed exchange folder by default. Other host folders are not exposed automatically. A guest with read-write access to a deliberately shared folder can change its contents.
- Chinese input methods are installed and configured inside Omarchy by the user; Mac input-method passthrough is not provided. See [Chinese input](docs/OMARCHY_INPUT.md).

For setup, display, input, and signing problems, see the
[troubleshooting guide](docs/TROUBLESHOOTING.md).

### Command line and headless mode

The Homebrew cask links `riftvm` into Homebrew's executable prefix. Every
command writes one schema-versioned JSON object and uses deterministic exit
codes.

Discovery and inspection commands cover both bundle layouts, so `list` shows the
Omarchy machine you actually created:

- a general VM bundle with `config.json` in its root, which is what
  `install-image` produces;
- an Omarchy machine with `Workspace/Configuration.json`, its `Disk.asif` and
  its `MachineIdentifier` one level down.

```sh
riftvm list
riftvm inspect "Omarchy"
riftvm validate "/path/to/Omarchy.riftvm"
riftvm doctor
riftvm start "Imported Linux" --timeout 90
riftvm status "Imported Linux"
riftvm stop "Imported Linux" --timeout 30
riftvm install-image preinstalled-image.json --image disk.raw \
  --destination "$HOME/.riftvm/Imported Linux.riftvm" --timeout 300
```

`start`, `status`, and `stop` drive general machines only. An Omarchy machine
needs the guest agent and the Omarchy-specific machine builder, which the
headless path does not provide, so those three commands exit 69 with
`unsupported_layout` for that bundle rather than pretending to control it. Start
and stop Omarchy in the app.

Use `--root /path/to/library` one or more times when machines are stored outside
`~/.riftvm` (the CLI also looks in `~/RiftVM Virtual Machines` for bundles
created by earlier releases). Headless mode runs the signed RiftVM virtualization
process without presenting a VM window. Stop first requests a guest shutdown
and uses a bounded force-stop fallback.

`install-image` imports a decoded, bootable ARM64 raw disk described by the
versioned [preinstalled-image manifest](docs/PREINSTALLED_IMAGE_MANIFEST.md).
Both the CLI and signed app verify its logical size and SHA-256, and interrupted
installation leaves no partial machine bundle.

## Build from source

1. Clone this repository.
2. Open `RiftVM/RiftVM.xcodeproj` in Xcode.
3. Select the **RiftVM** scheme and your Mac as the run destination.
4. Choose your own development team and bundle identifier if code signing requires it.
5. Build and run with <kbd>⌘R</kbd>.

See the [documentation index](docs/README.md) for troubleshooting, image formats,
guest integration, graphics architecture, and distribution details.

### Linux graphics backends

Omarchy defaults to Custom VirGL: Guest Mesa VirGL commands are rendered
through virglrenderer and ANGLE on Metal. If the runtime cannot initialize,
startup reports an error instead of switching to Apple Virtio.

| Machine / configuration | Graphics path |
| --- | --- |
| Omarchy created from the home screen | Custom VirGL by default; Apple Virtio is an explicit per-machine option |
| Imported or general Linux VMs | Custom VirGL for prepared guests; select Apple Virtio for installation or compatibility |

Choose **Settings → Display → Graphics Backend** for each Linux machine. Shut
down before switching. A saved machine state must first be resumed and shut down,
or discarded. The choice is stored with the VM and is never silently changed after
a startup failure. Custom VirGL requires compatible Linux guest drivers and the RiftVM Guest Agent;
Apple Virtio may use software rendering for Linux 3D.

Custom VirGL supports zero-copy scanout presentation and dynamic resolution.
It does not support memory-state save/restore because guest RAM alone cannot
reconstruct renderer contexts and resources. Stopped-VM file snapshots remain
supported. Omarchy recovery points protect the stopped disk and machine
configuration; they do not restore running GPU state.

Implementation and validation details are in the
[Custom VirGL architecture notes](docs/CUSTOM_VIRGL_ARCHITECTURE.md),
[performance guide](docs/VIRGL_PERFORMANCE.md), and isolated
[prototype record](Experiments/VZVirtioGPUPrototype/README.md).

If a VM opens without a usable window, input appears only after pointer
movement, full screen is stretched, Command-to-Super shortcuts fail, setup
loops, or a release repeatedly asks for Keychain access, start with the
[troubleshooting guide](docs/TROUBLESHOOTING.md). It separates host display
problems, guest Agent/compositor problems, image compatibility, and release
signing problems so that one workaround does not hide a different failure.

## Guest image

Choose **Prepare Omarchy**. RiftVM downloads the pinned Factory release, verifies
its signed manifest and image digest, creates a private writable disk and machine
identity, then guides you through owner setup. Generic Linux distributions,
custom ISO installation, and macOS guests are intentionally outside RiftVM's
product scope.

## Direction

RiftVM is not trying to replace UTM, VirtualBuddy, Tart, or Lima. Its direction is narrower:

1. Make VM creation, launch, stop, recovery, and error handling reliable.
2. Keep local macOS 27 tests, signed releases, Homebrew distribution,
   diagnostics, and configuration migration reproducible. CI runs core, CLI,
   runtime, and build checks on the `xcode-27` runner, with Guest Agent checks on
   Ubuntu. Real VM, physical-display, and signed-release acceptance remain
   separate from build checks.
3. Expose a small, local automation surface so scripts and AI agents can create, start, inspect, and discard isolated VMs safely.

The automation layer will remain local-first, explicit, and opt-in. RiftVM will not embed an AI model or require a cloud account. See the [documentation index](docs/README.md) for maintained technical references.

## Contributing

Issues and focused pull requests are welcome. Reliability fixes, reproducible bug reports, tests, accessibility improvements, and documentation updates are especially useful.

When reporting a VM problem, include the host macOS version, Mac model/chip, guest OS and image source, and the last operation performed. Do not attach VM disks or logs containing secrets.

## Community

- [GitHub Issues](https://github.com/riftvm/riftvm/issues) for bugs, questions, and focused feature requests
- [Discord](https://discord.gg/eGzEaP6TzR) for informal conversation

## License

RiftVM is available under the [MIT License](LICENSE).
