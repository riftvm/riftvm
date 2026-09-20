# The wallpaper that does not come back after a theme change (2026-09-20)

A 0.5.1 user reported two things: switching Omarchy themes often left no
wallpaper at all, and the screen sometimes showed "a page with the word omarchy
on it". This record answers whether either is RiftVM's doing.

The wordmark page is Omarchy's screensaver, working as configured. The missing
wallpaper is real and reproduces on demand. Every measurement here puts it in
Omarchy's theme-change path, not in RiftVM. The mechanism inside Omarchy's shell
was **not** established.

Machine: throwaway `v4.0.3-riftvm.15`, 4 vCPU and 8 GB, created under
`/private/tmp`, driven entirely through a shared-folder job runner. The host ran
harness builds carrying the refusal logging added in 0.5.2, extended part way
through with the two `TRANSFER_3D` lines described below.

## What the host did during all of it

Nothing was refused. Across roughly 110 theme changes and several hundred
wallpaper loads, `com.riftvm.app` logged **zero** entries at error level: no
`CTX_CREATE renderer-refused`, no `RESOURCE_CREATE_2D/3D` rejection, no
`RESOURCE_ATTACH_BACKING` refusal, and — once instrumented — no `TRANSFER_3D`
rejection or refusal either. The GLES context count reached 37 during login and
stayed there, so nothing leaked there.

## The wordmark page is the screensaver

`~/.config/omarchy/shell.json` ships:

```json
"idle": { "screensaver": 150, "lock": 300 }
```

After 150 seconds without input Omarchy runs `omarchy-branding-screensaver`,
which draws the OMARCHY wordmark; at 300 seconds it locks. That is the page in
the report. `omarchy-toggle-idle stay-awake` suppresses it.

It also wrecked the first investigation run: a job runner generates no input, so
a sweep spent its second half photographing the screensaver and then the lock
screen. `Tools/DeveloperDay/guest/runner.sh` now disables the shell's idle timer
at startup — stopping `hypridle` is not enough, because Omarchy's shell keeps
its own.

## Measuring the wallpaper

Screenshot the bare desktop with `grim`, scale the wallpaper the way the
compositor scales it, and compare with `magick compare -metric RMSE`. A correct
wallpaper scores about 0.03; a blank desktop scores above 0.20.

Two traps cost a run each:

- **Close the terminal first.** Tiled full screen it covers the wallpaper
  completely, so every sample measures the terminal.
- **Compare against the aspect-filled wallpaper**, not the file. The wallpapers
  are 3:2 and the screen is 16:9, so a naive average differs legitimately.

## What triggers it

Setting a background never failed. Changing a theme fails about half the time.

| On a freshly booted session | Blank |
| --- | --- |
| 6 × `omarchy-theme-bg-set` with a 1920×1080 wallpaper | 0 |
| 6 × `omarchy-theme-bg-set` with a 5000-pixel-wide wallpaper | 0 |
| `omarchy-theme-set`, 40 switches | first blank at the **3rd**; **24 of 40** blank |

The rate climbs as the session goes on: 5 blank in the first ten switches, 7 in
the second ten, 5 in the third, 7 in the last.

Both paths end in the same place — quickshell renders a background layer from an
image file — and the same file that blanks under `omarchy-theme-set` renders
correctly under `omarchy-theme-bg-set`. What separates them is everything else
`omarchy-theme-set` does around it.

Once a session has been through enough theme changes it degrades further, and
the degraded state is size-sensitive: after about 70 switches, the same wallpaper
at two sizes gave

| In a long-running session | Blank |
| --- | --- |
| 1920×1080 | 0 of 10 |
| 5000 px wide | 7 of 10 |

which is the shape of a resource running out somewhere. It is not our budgets:
those refusals are logged and none appeared.

## It is not RiftVM's pixel path

After a failure:

| Action | RMSE |
| --- | --- |
| Wait 25 seconds | 0.248 — still blank |
| `hyprctl dispatch forcerendererreload` | 0.223 — still blank |
| Re-apply the monitor | 0.223 — still blank |
| Re-issue `omarchy-theme-bg-set` with the **same file** | **0.032 — correct** |

Making Hyprland re-render changes nothing, so what RiftVM presents is a faithful
picture of what the guest composited: the shell's background layer really is
empty. The bar and the notification layer, drawn by the same quickshell process
through the same GL context and the same VirGL path, keep rendering correctly
throughout every failure.

## What was ruled out

- **A refused GPU request**, at every layer that can refuse one, including the
  two `TRANSFER_3D` paths instrumented during this investigation.
- **Slow decoding.** The wallpaper never appears, however long it is left.
- **A lost or exhausted GL context.** Context count flat at 37; the bar from the
  same context keeps drawing.
- **Wallpaper size on its own.** A 5000-pixel wallpaper is fine on a fresh
  session; it only fails once the session has degraded.
- **The two-second IPC timeout** in `omarchy-theme-set`'s
  `shell_ipc() { timeout 2 omarchy-shell "$@"; }`. This looked compelling and is
  wrong: the `background themeTransition` call returns in **29 ms with rc=0**.
  It is asynchronous, so the timeout never fires.
- **The transition path specifically.** Once a theme change has blanked the
  desktop, `background themeTransition` and plain `background set` fail alike,
  5 of 8 each.

An earlier attempt to raise that timeout by shadowing `timeout` on `PATH`
produced a *worse* result, 8 failures of 8. That shim was broken, not the
finding: `omarchy-shell` itself runs `timeout --kill-after=1s 2s qs …`, and a
shim that blindly dropped one argument turned it into a command that does not
exist. A corrected shim replacing only the duration operand produced the 29 ms
measurement above.

## What this means for RiftVM

Nothing to fix here. The device refuses nothing, and the compositor's output is
presented faithfully. A user who hits it can bring the wallpaper back without
switching themes again:

```sh
omarchy-theme-bg-set "$(readlink -f ~/.local/state/omarchy/current/background)"
```

Not claimed: the mechanism inside quickshell is unknown; nothing was reported or
fixed upstream; and the failure was never reproduced on hardware, so whether a
VM's slowness is what makes it this frequent is untested. A guest-side memory or
handle leak across theme changes fits the size-sensitivity above and was not
investigated.

## Ghostty

Ghostty is not in the image. Its 797 packages include `foot`, which is what
`xdg-terminal-exec` launches, and no `ghostty` at any version. A separately
installed Ghostty is a GTK4 client that has to obtain its own OpenGL context,
and its failure to do so is not covered by anything above.
