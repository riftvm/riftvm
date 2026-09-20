# What works in Omarchy under RiftVM (2026-09-20)

A sweep of the features an Omarchy user actually reaches for, run on a throwaway
`v4.0.3-riftvm.15` machine (4 vCPU, 8 GB) through a shared-folder job runner.
The question was whether anything common is broken, and whether any of it is
RiftVM's fault.

**Nothing found in this sweep is a RiftVM defect.** 24 of 26 checks pass, the two
that do not are the guest kernel and a package the image leaves out, and the
device logged nothing at error level throughout.

## What passes

| Area | Checks |
| --- | --- |
| Capture | `grim` full screen (1920×1080) and region, OCR of a rendered image through `tesseract` |
| Clipboard | `wl-copy`/`wl-paste` for text and for PNG |
| Notifications | `notify-send`, `omarchy-notification-send` |
| Apps | Chromium 153 (`--version` and a headless render), Neovim headless, mpv 0.41, btop, lazygit, nautilus, imv |
| Network | NetworkManager reports connected; HTTPS to github.com returns 200 |
| Session | `hyprctl` 0.56.1, power profiles list, 22 themes, fcitx5 running |
| Shared folder | read and write through `/mnt/mac` |
| Windows | spawn, workspace switch and back, fullscreen toggle, float toggle |

Two check *scripts* were wrong rather than the feature: a `wl-copy` that
daemonizes holds the pipe open and hangs command substitution unless it is
detached, and two `hyprctl` assertions matched the wrong output shape.

## Audio does not work, and it is fixable

The guest has no sound. PipeWire falls back to `auto_null`, so every application
plays into nothing.

RiftVM is not at fault: it configures `VZVirtioSoundDeviceConfiguration` with a
host output sink, and the device is present on the guest's PCI bus —

```
00:09.0 Multimedia audio controller: Red Hat, Inc. Virtio 1.0 sound (rev 01)
```

The guest simply has no driver for it. Arch Linux ARM's `linux-aarch64` 7.2.6-1
is built with:

```
# CONFIG_SND_VIRTIO is not set
```

and `modinfo virtio_snd` reports no such module.

**The driver builds and works.** Against the stock kernel's own headers, with
`sound/virtio` taken from the matching upstream tarball:

```sh
sudo pacman -S --needed linux-aarch64-headers
curl -sSLO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.6.tar.xz
tar -xf linux-7.2.6.tar.xz linux-7.2.6/sound/virtio
cd linux-7.2.6/sound/virtio   # obj-m += virtio_snd.o with the eight objects
make -C /lib/modules/$(uname -r)/build M=$PWD modules
sudo insmod ./virtio_snd.ko
```

It compiles without a warning worth repeating, and the card appears at once:

```
 0 [SoundCard      ]: virtio-snd - VirtIO SoundCard
                      VirtIO SoundCard at pci/0000:00:09.0/virtio5
192 alsa_output.pci-0000_00_09.0.stereo-fallback  PipeWire  float32le 2ch 48000Hz
```

That sink becomes the default, unmuted. A generated 440 Hz tone plays through
`pw-play` and through `mpv`, both exit 0, the sink moves to `IDLE`, and neither
PipeWire nor WirePlumber logs an error.

Shipping this means a decision, not just a patch: the module has to survive
`omarchy-update` pulling a new kernel, so the image would carry `dkms` and
`linux-aarch64-headers` (on the order of 100 MB) and vendor `sound/virtio`,
which is not guaranteed to compile against a future kernel series. The
alternative is Arch Linux ARM enabling `CONFIG_SND_VIRTIO` upstream. **Left for
a decision rather than done here**, because it changes every image.

## Menu entries with nothing behind them

The image deliberately omits hardware packages that mean nothing in a VM, but
Omarchy still ships the commands, so the menu offers them:

| Entry | Command | Tool | Behaviour |
| --- | --- | --- | --- |
| Screen recording | `omarchy-capture-screenrecording` | `gpu-screen-recorder` absent | exits 0, does nothing |
| Display brightness | `omarchy-brightness-display` | `brightnessctl`, `ddcutil` absent | exits 0, does nothing |
| Night light | `omarchy-toggle-nightlight` | `hyprsunset` absent | `Error: Command not found: "hyprsunset"` |
| Bluetooth | `omarchy-bluetooth-power` | `bluetoothctl` absent | prints usage |

Brightness, night light and Bluetooth have no meaning on a virtual machine.
**Screen recording does**, and it is the one worth restoring or hiding.

Screen *sharing* is fine: `hyprland-share-picker` is present. Only the separate
`hyprland-preview-share-picker` is excluded.

## What the host logged

Zero entries at error level from `com.riftvm.app` across the whole sweep, on all
seven refusal paths.

## Not claimed

Audio was proved to work only with a hand-built module on one machine; no image
change was made or tested. Screen recording was not tested with a recorder
installed. Sleep and wake, external displays and long sessions are out of scope
here, as they are in the other records. Keyboard-driven menu navigation was not
exercised — these checks drive the guest through `hyprctl` and the CLI.

Related: [the wallpaper record](../wallpaper-theme-switch-2026-09-20/README.md).
