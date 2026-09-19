# V1 real-guest pass, September 18, 2026

Host: this Mac, macOS 27, two 3840x2160 displays at 1920x1080 points. Guest: a
disposable machine from factory `v4.0.3-riftvm.9` (guest agent `4999f06`)
under `/private/tmp`, driven through the local acceptance harness built from
the `fix/v1-deterministic-display-input` branch. Input was injected with
CGEvent; results were read from the guest through the shared folder and from
the host's persistent log.

The guest got `/etc/xdg/uwsm/env-hyprland` and
`/etc/sddm.conf.d/20-riftvm-cursor-plane.conf` by hand, exactly as the image
now ships them (riftvm-omarchy-aarch64-image `e33b9fc`).

| Checklist item | Result | Evidence |
| --- | --- | --- |
| 1 Cold start keeps one mode | pass | four boots; only `VirGL display kept`, never `display mode requested`; `hyprctl monitors` 1920x1080 scale 1 |
| 2 Wallpaper after cold start | pass (4/4) | screenshots after first boot, relogin, two reboots |
| 4 Leave/resize/re-enter full screen | pass | view 1920x1011 -> 1080x639 -> 1100x579 -> 1920x1011, guest stayed 1920x1080, wallpaper intact |
| 5 Pause and resume | pass | paused screen shown; guest accepted typing after resume |
| 6 One pointer | pass with the guest config | `-x` capture has no cursor pixels; system cursor is the 64x64 guest image; mid-motion `-C` capture shows one cursor on the pointer's path |
| 6 One pointer, factory `.9` as shipped | **fail** | aquamarine never gets the cursor plane; Hyprland paints the pointer (see e33b9fc) |
| 11 200 clicks | pass | guest evdev: 200 BTN_LEFT down, 200 up, all on `RiftVM Absolute Pointer`; right and middle 1/1 |
| 14 Fast typing | pass | 399 bytes of mixed case and shifted symbols, byte-identical |
| 16 Caps Lock as Compose twice | pass | `éé` |
| 18 Trackpad scroll speed | pass | 200 points -> 20 REL_WHEEL detents (66 before) |
| 20 Graphics stress | pass (90 s, not 30 min) | 60 fps, 0 failures, 0 drawable misses, 0 fence timeouts, p95 frame 0.22 ms |
| 21 Clipboard both ways | pass | host->guest and guest->host text |
| Screen lock and unlock | pass | unlocked by typing, no pointer movement |

Found and fixed during the pass (host `18e9c33`, `3fb6afd`, `8cc05ad`):

- the acceptance harness opened the user's real Omarchy instead of its
  temporary machine;
- one 3D fence timed out at login and, with ordered completion, froze the
  display for 10 s;
- a device reset was recorded as "the guest hid its cursor", blanking the
  macOS cursor for the whole session.

Not exercised: the new guest agent (relative-mode click routing, horizontal
wheel), because factory `.9` carries agent `4999f06`; Command shortcuts
(the harness had no Accessibility permission); key repeat; real host
sleep/wake; a 30-minute video soak.
