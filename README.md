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

Create an **Omarchy workspace** from a verified preinstalled image, or a
**macOS virtual machine** from an Apple restore image. Both run locally using
Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization).

Prefer a direct download? Get the signed and notarized app from
[GitHub Releases](https://github.com/riftvm/riftvm/releases/latest).

## Create your first workspace

1. Open RiftVM and choose **Omarchy** or **macOS** from the home screen or the **+** menu. Your selection carries into the creation form.
2. Choose a name, location, and hardware settings. The default location is `~/RiftVM Virtual Machines`; RiftVM remembers a custom location when you choose one.
3. Click **Create Omarchy** or **Create Workspace** to download and verify the required image. You can continue in the background, then launch from the workspace list. Omarchy guides you through owner setup on first boot.

Each workspace has its own writable disk and machine identity. Downloaded
images are cached for reuse; Omarchy still needs a connection to verify its
release manifest when creating a workspace, even with a cached image.

## What it does

- Runs Omarchy and macOS locally through Apple's native virtualization stack
- Creates Omarchy from a signed, verified factory image with guided owner setup
- Creates macOS machines from a local IPSW, a selected release, or Apple's latest compatible restore image
- Reuses downloaded images and gives each workspace its own writable disk and machine identity
- Integrates Omarchy keyboard shortcuts, dynamic display sizing, text and image clipboard exchange, and notifications through an authenticated guest agent
- Exchanges files through **Open Shared Folder** and **Import Files**; Omarchy sees its private exchange folder at `/mnt/riftvm-shared`
- Creates protected Omarchy recovery points before updates and restores them while the guest is stopped
- Provides macOS machine configuration, stopped-machine snapshots, cloning, and checksum-verified `.riftvmexport` import/export in the general VM flow

### Update and recover Omarchy

Use **Updates → Prepare for Omarchy Update…** to stop the guest and create a
protected recovery point. Start Omarchy and update it from its own menu. If the
update causes problems, stop it and restore the saved point from **Recovery**.

**Updates → Create Workspace from Latest Image…** creates a separate workspace
from the signed factory channel. Updating RiftVM itself or downloading a newer
factory does not replace your existing guest disk. See [Updates and recovery](docs/UPDATES_AND_RECOVERY.md).

## Requirements

- An Apple silicon Mac
- macOS 27 or later
- A supported macOS restore image, or the verified Omarchy image downloaded by RiftVM

## Limits to know

- Apple silicon and macOS 27 or later are required. Intel Macs and generic Linux ISO installation are outside the supported creation flow.
- Stop a machine before taking or restoring a file snapshot. Keep backups of important guests.
- Omarchy uses Custom VirGL graphics and disk recovery points. Use its Start/Stop and Recovery controls; GPU memory-state save/restore is not supported.
- Omarchy shares only its managed exchange folder by default. Other host folders are not exposed automatically. A guest with read-write access to a deliberately shared folder can change its contents.
- Chinese input methods are installed and configured inside Omarchy by the user; Mac input-method passthrough is not provided. See [Chinese input](docs/OMARCHY_INPUT.md).

For setup, display, input, and signing problems, see the
[troubleshooting guide](docs/TROUBLESHOOTING.md).

### Command line and headless mode

The Homebrew cask links `riftvm` into Homebrew's executable prefix. Every
command writes one schema-versioned JSON object and uses deterministic exit
codes. These commands operate on general VM bundles containing `config.json`;
the dedicated Omarchy workspace layout (`Workspace/Configuration.json`) is not
currently supported by CLI discovery or lifecycle commands. Use the app to
manage Omarchy workspaces created from the home screen. For a general VM:

```sh
riftvm list
riftvm inspect "My macOS VM"
riftvm validate "/path/to/My VM.riftvm"
riftvm doctor
riftvm start "My macOS VM" --timeout 90
riftvm status "My macOS VM"
riftvm stop "My macOS VM" --timeout 30
riftvm install-image preinstalled-image.json --image disk.raw \
  --destination "$HOME/RiftVM Virtual Machines/Imported Linux.riftvm" --timeout 300
```

Use `--root /path/to/library` one or more times when machines are stored outside
`~/RiftVM Virtual Machines`. Headless mode runs the signed RiftVM virtualization
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

Omarchy uses Custom VirGL exclusively: Guest Mesa VirGL commands are rendered
through virglrenderer and ANGLE on Metal. If the runtime cannot initialize,
startup reports an error instead of switching to Apple Virtio.

| Workspace / configuration | Graphics path |
| --- | --- |
| Omarchy created from the home screen | Custom Virtio GPU → VirGLRenderer → ANGLE/Metal; no Apple Virtio fallback |
| macOS guest | Apple native Mac graphics |
| General Linux VM with Custom VirGL enabled | Custom Virtio GPU → VirGLRenderer → ANGLE/Metal, with Apple Virtio fallback if initialization fails |

Custom VirGL supports zero-copy scanout presentation and dynamic resolution.
It does not support memory-state save/restore because guest RAM alone cannot
reconstruct renderer contexts and resources. Stopped-VM file snapshots remain
supported. Omarchy recovery points protect the stopped disk and workspace
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

## Guest images

### macOS

Pick a macOS version from the built-in list in the creation flow (or use the latest supported restore image), or select a compatible `.ipsw` restore image from disk. Apple publishes current restore images through `Virtualization.framework`; third-party indexes such as [ipsw.me](https://ipsw.me/product/Mac) can help locate older versions.

### Omarchy

Choose **Omarchy** from the home screen or **+** menu. RiftVM downloads the pinned Factory release, verifies its signed manifest and image digest, creates a private writable disk and machine identity, then guides you through owner setup. Generic Linux distributions and custom ISO installation are intentionally outside RiftVM's product scope.

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
