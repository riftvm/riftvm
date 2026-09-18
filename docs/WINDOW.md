# The RiftVM window

RiftVM has one window and one machine: Omarchy. This file records the shape of
that window — the "centreline" — so a later change can be checked against it
instead of against a memory of the UI. It describes the 0.3.0 window; the 0.2.0
build still had a control center, a workspace list, and a separate creation
window.

## The centreline

The window is a small state machine. Everything Omarchy can do hangs off it as a
toolbar menu or a sheet; nothing opens a second window.

```
                      Launch RiftVM
                           │
                           ▼
             ┌──────────────────────────────┐
             │  Window "RiftVM" (only one)  │
             └───────────────┬──────────────┘
                             │
                 does Omarchy exist on this Mac?
                   │                       │
                 no│                     yes│
                   ▼                       ▼
        ┌───────────────────┐    ┌──────────────────────┐
        │ A  Prepare        │    │ B  Start / Stopped   │
        │   storage,        │    │  [▶ Start Omarchy]   │
        │   resources       │    └──────────┬───────────┘
        └─────────┬─────────┘               │ Start
                  │ prepared                │
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
    on-disk format needs migration → migrate
    the bundle needs repair        → repair / preserve and reinstall
    the guest failed to start      → inline error + Stop and Enable Recovery
    preparation finished           → the window switches from A to B
```

State A prepares; state B starts; state C runs; stopping returns to B. There is
no workspace list because there is one machine, and no name to choose because it
is always Omarchy.

## Wireframes

**A · Prepare** (no Omarchy yet). Storage and resources are the whole form.
The exchange folder is `~/.riftvm/RiftVM Shared` — beside the machine bundle,
not inside it, so the folder carries the name the UI uses and survives removing
the machine.

```
┌─ RiftVM ────────────────────────────────────────────[ Prepare Omarchy ]─┐
│                             ▢ Omarchy                                 │
│              A focused Arch Linux desktop, ready on first boot.       │
│                                                                       │
│  ✓ The signed Omarchy image is downloaded, verified, and cached when  │
│    you prepare it.                                                    │
│                                                                       │
│  Stored in   ~/.riftvm/Omarchy.riftvm                          ✎      │
│  ─────────────────────────────────────────────────────────────────    │
│  ▸ Resources       8 CPU · 16 GB memory · 64 GB disk                  │
│  ─────────────────────────────────────────────────────────────────    │
│  ▸ File exchange   RiftVM Shared (beside the machine)                 │
│                                                                       │
│                        [ Prepare Omarchy ]                            │
└───────────────────────────────────────────────────────────────────────┘
```

**A2 · Preparing.** The form is replaced by the meter and the live stage; a
closed window does not cancel the download (the menu bar keeps reporting it).

```
┌─ RiftVM ──────────────────────────────────────────────────────────────┐
│      ████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  meter        │
│                        Preparing Omarchy                              │
│              You can keep using RiftVM while this finishes            │
│  ┌───────────────────────────────────────────────────────────────┐    │
│  │ Downloading and verifying Omarchy        2.1 GB of 5.3 GB     │    │
│  │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  39%     │    │
│  └───────────────────────────────────────────────────────────────┘    │
│  ▸ Details   12:04:11  Fetching the signed Omarchy Factory manifest   │
│  [ Cancel Download ]                    Creation continues if you close │
│                                         this window                    │
└───────────────────────────────────────────────────────────────────────┘
```

**B · Start / stopped.** What the window shows on every later launch.

```
┌─ Omarchy ──[ Omarchy ▾ ] [ Graphics ▾ ] [ Integration ▾ ] [ … ]────────┐
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
`Repair and Recheck`, `Preserve and Reinstall…`) are unchanged from earlier
builds.

## The toolbar

| Menu | Items |
| --- | --- |
| `Omarchy ▾` | Snapshots… · Show in Finder · Remove Omarchy… |
| `Graphics ▾` | Custom VirGL, any problem, and a note that RiftVM renders through its own VirGL device |
| `Integration ▾` | agent status, clipboard, microphone, notifications |
| `Updates ▾` | app version, Prepare for Omarchy Update…, signed factory channel |
| `Recovery ▾` | recovery points, restore, create backup |
| buttons | Open Shared Folder · Import Files · Pause / Restart / Stop / Resume |

**Remove Omarchy…** asks first, stops a live guest before touching the disk,
moves the bundle to the Trash, clears the record, and returns the window to
state A. `RiftVM Shared` sits beside the bundle, so the files you exchanged
with Omarchy stay on the Mac. There is no rename: the name is always Omarchy.

## What the window deliberately does not have

- No control center, no workspace list, no workspace switcher: one window, one
  machine.
- No name field: one machine does not need one.
- No second creation window: preparing happens in this window.
- No automatic start at launch: the window opens on **Start Omarchy** and waits,
  because a 64 GiB guest booting on its own is not something to hide.
- No mode picker for a second guest kind: Omarchy is the only machine RiftVM
  prepares.
