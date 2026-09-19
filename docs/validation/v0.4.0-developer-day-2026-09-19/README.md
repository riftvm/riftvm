# RiftVM 0.4.0 developer-day validation (2026-09-19)

Can a developer do their day's work inside Omarchy on RiftVM? This record
covers a scripted pass on disposable machines: common Git work, file editing,
a frontend stack, other toolchains, containers, installing and removing
software, VS Code, and Omarchy's keyboard shortcuts with Command as Super. It
also covers the shared-folder change in 0.4.0.

Machines: fresh `v4.0.3-riftvm.12` and `v4.0.3-riftvm.13` factories on macOS 27,
Apple silicon, 4 vCPU and 8 GB for the guest. Command-line steps ran inside the
desktop session through a job runner in a shared folder. Shortcut steps sent
real key events to the RiftVM window and read the result back from
`hyprctl -j`. The test machines had passwordless `sudo`; a user types their
password instead.

## Result

A frontend or full-stack developer can do nearly all of their work in Omarchy
on RiftVM. Every product-level step passed on `.13`. The one image gap found on
`.12`, missing `make` and `patch`, is fixed in `.13`, which installs
`base-devel`.

| Area | Steps | Result on `.13` |
| --- | --- | --- |
| Git | config, commit, branch and `--no-ff` merge, conflict and resolution, rebase, stash, tags, worktrees, `diff` plus `patch`, HTTPS clone and blobless clone from GitHub, `gh` | pass |
| Editing | Neovim (headless edit), ripgrep, fd, fzf, jq, 1 GiB write and hash | pass |
| Frontend | Node 26 and npm, Vite React TypeScript scaffold, install, build, dev server, HMR on file change, headless Chromium rendering the app, Vitest, ESLint, Prettier, `tsc -b`, pnpm, bun, Tailwind 4, Playwright with the system Chromium, Next.js create and build | pass |
| Other toolchains | Python venv and pip, uv, C with make, Go, Rust with cargo | pass |
| Containers | Docker enable, `hello-world`, build and run an image, Compose with PostgreSQL | pass |
| Packages | pacman install and uninstall, AUR build with yay, then remove | pass |
| VS Code | install with Omarchy's installer (1.135, arm64), window renders, edit and save a file, Super+C and Super+V | pass |
| Clipboard | text and PNG in both directions, including with every user folder read-only | pass |

Two scripted steps failed because of the test scripts, not the product. A
`git bisect` fixture started from a commit without its marker file. A
Chromium check grepped for template text that the current Vite template no
longer contains; the corrected check passed.

### Omarchy shortcuts with Command as Super

With the RiftVM window focused, these reached Omarchy and did what Omarchy
documents:

- Terminal, browser, file manager and editor: Super+Return, Super+Shift+B,
  Super+Shift+F, Super+Shift+N.
- Menus: Omarchy, apps, keybindings, system, clipboard manager, emoji, capture
  (Super+Space, Super+Alt+Space, Super+K, Super+Escape, Super+Ctrl+V,
  Super+Ctrl+E, Super+Ctrl+C).
- Workspaces: switch, move a window, next, scratchpad (Super+1…5,
  Super+Shift+2, Super+Tab, Super+S).
- Windows:
  - focus and swap: Super+arrows, Super+Shift+arrows;
  - layout: split (Super+J), floating (Super+T), full screen (Super+F), full
    width (Super+Alt+F), group (Super+G);
  - size and chrome: resize (Super+Minus/Equal), transparency (Super+Backspace),
    bar (Super+Shift+Space);
  - close (Super+W); cycle with Alt+Tab.
- Command-Q stays in Omarchy and does not quit RiftVM.

Each layout shortcut was checked on an empty workspace. On a workspace whose
window Omarchy's screensaver had left in full screen, new windows inherit the
full-screen state, as Hyprland intends.

While Omarchy has focus, Command-Tab, Command-Space and Control-Command-F also
go to Omarchy. **Control-Option** frees the pointer so the Dock, the menu bar
and RiftVM's toolbar can be reached. 0.4.0 shows this in a hint when Omarchy
starts and in the Integration menu; it was not documented before.

## Shared folders

- **New machine.** `SharedFolders.json` lists the folders, beside the machine
  and outside `Workspace/`.
  - The `.13` Agent reports `clipboard-staging-directory-v1` seconds after
    boot, before anyone logs in. RiftVM then switches to the multi-folder
    layout: `/mnt/riftvm-shared/.riftvm` plus one directory per folder.
  - Later boots start in that layout.
- **Existing machine.** A `.12` machine opened by 0.4.0 moved `RiftVM Shared`
  to `riftvm-shared` with its files.
  - It kept the single-folder layout, with the clipboard working in both
    directions.
  - After the `.13` Agent was installed, it switched to the multi-folder layout
    and the clipboard kept working.
- **Read-only.** A read-only folder refuses writes in Omarchy (`Operation not
  permitted`). While the only folder is read-only, Open Shared Folder and
  Import Files are unavailable.
- **Edits apply at the next start.** An early build applied edits live. A probe
  showed that replacing the running share makes the working directory of every
  Guest process inside any shared folder disappear (ENOENT for `.`), and two
  running scripts died that way.
  - Edits are now saved at once and shown as "Omarchy sees these changes after
    it restarts", with a Restart Omarchy button.
  - During an edit the probe saw no errors, and the folder stayed writable
    until the restart.
  - After Restart Omarchy, the folder was read-only as set.
  - A removed folder was gone after the next start, and its files stayed on
    the Mac.

## Not covered

Adding a folder through the open panel could not be scripted: the panel's
Go To field ignored synthetic key events. Adding appends to the same saved list
that removing and Read Only use. Also not measured: long sessions, sleep and
wake, and heavy parallel builds beyond 8 GB of guest memory.
