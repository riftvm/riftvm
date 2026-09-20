# RiftVM 0.5.0 validation (2026-09-19)

0.5.0 removes every compatibility and general-VM path, about 18,000 lines. The
question this record answers is whether the product still does everything it
did, on a machine created from factory `v4.0.3-riftvm.14`, whose Agent accepts
clipboard items only in the `.riftvm` staging folder.

Machine: fresh `v4.0.3-riftvm.14`, macOS 27 on Apple silicon, 4 vCPU and 8 GB
for the guest, two shared folders (`rs14-main` read-write, `rs14-docs`
read-only). Command-line steps ran through a job runner in the shared folder.
Shortcut steps sent real key events to the RiftVM window and read the result
back from `hyprctl -j`. The test machine had passwordless `sudo`; a user types
their password.

## Result

Everything passed. Nothing a user does in the window changed.

| Area | Result |
| --- | --- |
| First boot | Wallpaper present, one cursor, `~/Mac` absent, `make` and `patch` present |
| Shared folders | `/mnt/riftvm-shared` holds `.riftvm`, `rs14-main`, `rs14-docs`; the read-only folder refuses writes; the writable one exchanges files both ways |
| Clipboard | Text and PNG in both directions, staged in `.riftvm` and cleaned up |
| Editing the list | Removing a folder is saved at once, leaves the running guest untouched, and takes effect after **Restart Omarchy**; the folder's files stay on the Mac |
| Git | 17 checks: merges, conflicts, rebase, stash, tags, `bisect run`, worktrees, `diff`/`patch`, HTTPS and blobless clones, `gh` |
| Frontend | 16 checks: Vite React TypeScript build, dev server, HMR, headless Chromium render, Vitest, ESLint, Prettier, `tsc -b`, pnpm, bun, Tailwind 4, Playwright, Next.js |
| Other toolchains | Python venv and pip, uv, C with make, Go, Rust |
| Containers | Docker `hello-world`, an image build and run, Compose with PostgreSQL |
| Packages | pacman install and remove, AUR build with yay, VS Code 1.135 through Omarchy's installer |
| Editors | Neovim headless edit; VS Code opens, edits, saves, and copies and pastes with Super+C/V |
| Shortcuts | 29 of 30 Omarchy shortcuts with Command as Super: terminal, browser, file manager, editor, all menus, workspaces, window focus, swap, split, float, full screen, group, resize, close, Alt+Tab. Command-Q stays in Omarchy |

The bar toggle (Super+Shift+Space) is the one shortcut this run cannot assert:
it hides the bar without removing its layer surface, so `hyprctl` sees no
change. Screenshots in the 0.4.0 record show it working.

## What the removals did not break

- **Clipboard** keeps working with the Agent that no longer accepts an item at
  the mount root, including with every user folder read-only.
- **Recovery points and snapshots** still come from the shared snapshot
  manager, which the general-VM deletion left in place.
- **The release pipeline** verifies the signed app and that it trusts its
  pinned factory manifest, in place of the general-VM boot fixture it used
  before.
- **The CLI** reports machines with `list`, `inspect`, `validate` and `doctor`.

## Test harness changes made for this run

- `run.py --boot-unlock` types the password into the lock screen through the
  Agent, and `--desktop-command` opens a terminal and runs one command the same
  way. A test machine can now reach its desktop and start a job runner without
  taking the Mac's keyboard.
- The input tool refuses to post an event unless the target app is frontmost,
  and the shortcut driver aborts instead of taking focus back, after keystrokes
  leaked into another app earlier in the day.

## Follow-up: /mnt/mac (0.5.1)

With several folders each one sits below the mount point, so the default folder
read `/mnt/riftvm-shared/riftvm-shared`. 0.5.1 mounts the share at `/mnt/mac`.
Rechecked on a fresh `v4.0.3-riftvm.15` machine: `/mnt/mac` holds `.riftvm` and
both folders, `/mnt/riftvm-shared` is gone, the mount unit and both Agent
services use the new path, the read-only folder still refuses writes, clipboard
text and images still work in both directions, and the Git, frontend and
toolchain suites pass in full.

## Not covered

Adding a folder through the system open panel, whose Go To field ignores
synthetic key events. Removing and Read Only use the same saved list. Also not
measured: long sessions, sleep and wake, and builds beyond 8 GB of guest
memory.
