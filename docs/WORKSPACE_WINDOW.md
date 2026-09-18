# The workspace window

RiftVM has one window and one workspace. This file records the shape of that
window — the "centreline" — so a later change can be checked against it instead
of against a memory of the UI. It describes the 0.3.0 window; the 0.2.0 build
still had a control center and a separate creation window.

## The centreline

The window is a small state machine. Everything a workspace can do hangs off it
as a toolbar menu or a sheet; nothing opens a second window.

```
                      Launch RiftVM
                           │
                           ▼
             ┌──────────────────────────────┐
             │  Window "RiftVM" (only one)  │
             └───────────────┬──────────────┘
                             │
                 is there a prepared workspace?
                   │                       │
                 no│                     yes│
                   ▼                       ▼
        ┌───────────────────┐    ┌──────────────────────┐
        │ A  Prepare        │    │ B  Start / Stopped   │
        │   name, path,     │    │  [▶ Start Omarchy]   │
        │   resources       │    └──────────┬───────────┘
        └─────────┬─────────┘               │ Start
                  │ created                 │
                  └────────────┬────────────┘
                               ▼
                    ┌──────────────────────┐
             ┌─────▶│ C  Live (full screen)│
             │      │ [⏸][⟳][⏹]           │
             │      └──────────┬───────────┘
             │ Resume          │ Stop
             └──── C2 Paused ◀─┘
                               │
                               ▼
                          back to B

  Anything else stays in this window:
    workspace needs migration or repair → D: migrate / repair screens
    guest failed to start               → C inline error + Stop and Enable Recovery
    creation finished                   → the window switches from A to B
```

State A prepares; state B starts; state C runs; stopping returns to B. The
window never shows a workspace list, because there is exactly one workspace.

## Wireframes

**A · Prepare** (no workspace yet). The name, the location, and the resources
are the whole form.

```
┌─ RiftVM ────────────────────────────────────────────[ Create Omarchy ]─┐
│                             ▢ Omarchy                                 │
│                          Prepare Omarchy                              │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │  Name        [ Omarchy                                       ]  │  │
│  │  Save to     ~/.riftvm/Omarchy.riftvm                       ✎   │  │
│  │  ▸ Resources  8 CPU · 16 GB memory · 64 GB disk                 │  │
│  │  ▸ File exchange  RiftVM Shared · ready                         │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                         [ Create Omarchy ]                            │
└───────────────────────────────────────────────────────────────────────┘
```

**A2 · Preparing.** The form is replaced by the meter and the live stage; a
closed window does not cancel the download (the menu bar keeps reporting it).

```
┌─ RiftVM ──────────────────────────────────────────────────────────────┐
│      ████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  meter        │
│                        Preparing Omarchy                              │
│  ┌───────────────────────────────────────────────────────────────┐    │
│  │ Downloading and verifying Omarchy        2.1 GB of 5.3 GB     │    │
│  │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  39%     │    │
│  └───────────────────────────────────────────────────────────────┘    │
│  ▸ Details   12:04:11  Fetching the signed Omarchy Factory manifest   │
│  [ Cancel Download ]                        Creation continues if you   │
│                                             close this window           │
└───────────────────────────────────────────────────────────────────────┘
```

**B · Start / stopped.** What the window shows on every later launch.

```
┌─ Omarchy ──[ ⚙ Workspace ▾ ] [ Graphics ▾ ] [ Integration ▾ ] [ … ]────┐
│                             ▢ Omarchy                                  │
│                        Omarchy is stopped                              │
│           8 CPU · 16 GB memory · 64 GB disk                            │
│           ~/.riftvm/Omarchy.riftvm                                     │
│                       [ ▶ Start Omarchy ]                              │
└────────────────────────────────────────────────────────────────────────┘
```

**C · Live.** Starting the guest takes the window full screen; leaving full
screen keeps it running windowed. The guest keeps one display mode for the
session, so a resize costs host-side scaling only.

```
┌─ Omarchy · Running ────[ ⏸ Pause ] [ ⟳ Restart ] [ ⏹ Stop ] [ … ]──────┐
│  ┌───────────────────────────────────────────────────────────────────┐ │
│  │                    Omarchy desktop (guest canvas)                 │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│  Top banners appear only when something needs attention: a graphics     │
│  backend problem, a missing Accessibility permission, an acceptance run │
└────────────────────────────────────────────────────────────────────────┘
```

**C2 · Paused.** Frozen canvas with `Omarchy is paused` and `[ ▶ Resume Omarchy ]`.

**D · Repair.** The migration and repair screens (`Create Backup and Migrate`,
`Repair and Recheck`, `Preserve and Reinstall…`) unchanged from earlier builds.

## The toolbar

| Menu | Items |
| --- | --- |
| `Workspace ▾` | Snapshots… · Display Settings… · Rename… · Show in Finder · Remove Workspace… |
| `Graphics ▾` | the active backend, any problem, Display Settings… |
| `Integration ▾` | agent status, clipboard, microphone, notifications |
| `Updates ▾` | app version, Prepare for Omarchy Update…, signed factory channel |
| `Recovery ▾` | recovery points, restore, create backup |
| buttons | Open Shared Folder · Import Files · Pause / Restart / Stop / Resume |

**Remove Workspace…** asks first, stops a live guest before touching the disk,
moves the bundle to the Trash, clears the record, and returns the window to
state A. **Rename…** changes the display name only; the folder keeps its name.

## What the window deliberately does not have

- No control center, no workspace list, no workspace switcher: one window, one
  workspace.
- No second creation window: preparing happens in this window.
- No automatic start at launch: the window opens on **Start Omarchy** and waits,
  because a 64 GiB guest booting on its own is not something to hide.
- No mode picker for a second guest kind: Omarchy is the only workspace RiftVM
  prepares.
