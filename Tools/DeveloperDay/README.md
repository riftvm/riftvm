# Developer-day suite

Can a developer do their day's work inside Omarchy? These scripts answer that
on a disposable machine: common Git work, a frontend stack, other toolchains,
containers, installing and removing software, editors, and Omarchy's keyboard
shortcuts with Command as Super.

They are test tools, not product code. They assume a machine created by
`omarchy-workspace-acceptance-tool` under the temporary directory, never a real
one. Results from past runs are in
[docs/validation](../../docs/validation).

## How a run works

The Mac cannot type into the guest while you use the Mac: synthetic key events
go to whatever application is frontmost. So most of the suite goes through the
guest instead.

- `guest/runner.sh` runs inside the desktop session and executes any script
  dropped into `jobs/` beside it, writing `<job>.out` and `<job>.rc` next to it.
  Both sides see those files through the shared folder.
- The acceptance harness starts that runner for you: `run.py --boot-unlock`
  types the password into the lock screen through the Guest Agent, and
  `--desktop-command` opens a terminal and runs one command the same way.
- Only the shortcut suite needs the Mac's keyboard, because it tests how RiftVM
  turns a real Command chord into Omarchy's Super.

## Run the command-line suites

```sh
# 1. Create a disposable machine and two shared folders, then write
#    SharedFolders.json for it (see docs/validation for a worked example).

# 2. Start it, logging in and starting the runner through the Guest Agent.
echo "$PASSWORD" | python3 Tools/OmarchyAcceptanceHarness/run.py \
  "/private/tmp/riftvm-harness/RiftVM Acceptance.app" /private/tmp/test.riftvm \
  --scenario observe --password-stdin --boot-unlock \
  --desktop-command 'setsid -f bash /mnt/mac/<folder>/runner.sh'

# 3. Drop a job in and read its output.
J=/private/tmp/<folder>/jobs
RIFTVM_TEST_PASSWORD=$PASSWORD envsubst < Tools/DeveloperDay/guest/jobs/setup.sh > $J/setup.sh
cp Tools/DeveloperDay/guest/jobs/git.sh $J/dev-git.sh
until [ -e $J/dev-git.rc ]; do sleep 5; done; cat $J/dev-git.out
```

`lib.sh` gives each job a `step` helper that prints `PASS`/`FAIL`, a duration
and the last line of output, and appends the same to `results.tsv`.

- `jobs/setup.sh` — passwordless sudo for the test machine, and a look at the
  shared folders and build tools.
- `jobs/git.sh` — merges, conflicts, rebase, stash, tags, `bisect run`,
  worktrees, `diff`/`patch`, clones from GitHub, Neovim, ripgrep and friends.
- `jobs/fe.sh` — Vite with React and TypeScript: install, build, dev server,
  HMR, headless Chromium, Vitest, ESLint, Prettier, `tsc`, pnpm, bun, Tailwind,
  Playwright, Next.js.
- `jobs/be.sh` — Python and uv, C with make, Go, Rust, Docker and Compose,
  pacman and AUR install and removal, VS Code.

## Run the shortcut suites

These send real key events, so they need the RiftVM window frontmost. Build the
three small helpers first:

```sh
cd Tools/DeveloperDay/host
swiftc -O evt.swift -o evt && swiftc -O activate.swift -o activate && swiftc -O front.swift -o front
JOBS=/private/tmp/<folder>/jobs python3 keys.py <riftvm-pid>   # menus, apps, workspaces
JOBS=/private/tmp/<folder>/jobs python3 keys2.py <riftvm-pid>  # window layout, VS Code
JOBS=/private/tmp/<folder>/jobs python3 keys4.py <riftvm-pid>  # VS Code edit, save, copy/paste
```

`evt` refuses to post an event unless the target process is frontmost, and the
drivers abort instead of taking focus back, so a run stops the moment someone
starts using the Mac rather than typing into their windows.

Two things a run cannot assert, both known:

- **The bar toggle** (Super+Shift+Space) hides Omarchy's bar without removing
  its layer surface, so `hyprctl` reports no change. Check it in a screenshot.
- **Adding a folder** through the system open panel: its Go To field ignores
  synthetic key events. Removing and Read Only use the same saved list.
