# RiftVM 0.1.0 — paused work and handoff

Updated: 2026-09-07. Development and testing paused at the owner's request. Resume only when requested. This is an unfinished-work inventory, not release approval. No additional build, notarization submission, upload or VM mutation is part of this handoff.

## Baseline

- Apple Silicon; minimum macOS 27 Beta; English only; com.riftvm.app; version 0.1.0.
- Primary guests: Omarchy and macOS. Debian is the accepted generic ISO test guest; Ubuntu is optional.
- Installed candidate: signed build 26, source ca18a58. Latest evidence commit before this handoff: 30f88e7. Main branch was 32 commits ahead of its locally recorded origin/main; no fresh remote fetch was performed.
- Candidate ZIP SHA-256: 9fe7862c87c53fbd04cfc3dd7744b6a2fde4bc13719e14a015c140d12d21741e.
- Main worktree was clean before this document. Original EZVM remains outside the modification scope.
- Ordinary Omarchy typing latency / unresponsive Return is explicitly deferred for 0.1.0. It is not fixed, and the exception does not waive isolation or data recovery checks.

## Remaining work

| ID | Priority | Task / current gap | Completion evidence needed | Owner assistance |
|---|---|---|---|---|
| R01 | First | Standard guest saved-state resume failure can fall back to cold boot; identified, no fix yet | Preserve the saved session on failure, explicit recovery, regression test and signed runtime check | None expected |
| R02 | Before release | Real guest disk rollback not demonstrated | Create and modify a file inside the guest disk, restore the checkpoint, verify original bytes; shared-host files do not count | None expected; existing guest login only if inaccessible |
| R03 | Before release | Mixed Omarchy/macOS quit and restore not fully proven | Verify running/paused state and in-memory continuity; saved-file disappearance alone is insufficient | Only existing macOS guest login if needed and unavailable to automation |
| R04 | Before release | Cross-window modifiers, clipboard and notifications only partially verified | Two guests; focus switches, modifier release and correct clipboard/notification destination | None expected |
| R05 | Before release | Final-candidate fresh Omarchy setup incomplete | Public image download, owner setup, desktop and restart; cached startup is not a cold-download test | None expected |
| R06 | Before release | Login resolution, resize/fullscreen and all reopen routes incomplete | No content overlap, correct pointer alignment, window resize/fullscreen, Dock and menu-bar reopening | None expected; optional reproduction details/screenshots |
| R07 | Before release | Shared folders tested in backend and GUI separately | Final App guest-side read-only/read-write enforcement, revoke access and preserve host files | None expected; use temporary test folders |
| R08 | Before release | Portability has backend and partial GUI evidence | Final-candidate export/import/clone, historical ISO independence and restored guest boot | None expected |
| R09 | Before release | Final consolidated acceptance record missing | Artifact-bound evidence for all required gates; keyboard exception recorded separately | None expected |
| R10 | Release | Final notarization, clean download and Homebrew installation incomplete | One final candidate accepted by Apple, package verification and actual cask installation | If approval review still blocks upload: explicit approval of the exact final ZIP and Apple destination; provide account interaction only if required |
| R11 | Release | Latest commits not all pushed; release/site/tap publication incomplete | Push each intended repository, verify CI/Pages, release URLs and cask checksum | If approval review still blocks push: approval of the concrete repositories and commits, not credentials |
| R12 | Release | riftvm.com configuration not verified | DNS, Pages custom domain and HTTPS resolve correctly | Domain provider/access context when resuming; no password in this document |
| R13 | Deferred | Omarchy ordinary input latency / Return | Separate investigation using macOS 27 SDK/runtime, native keyboard and guest/display diagnostics | Optional exact macOS/Xcode Beta versions and a short reproduction; no immediate action required |

## Completed evidence to retain

| Area | Evidence / limits |
|---|---|
| Build and signing | Build 26 resource, entitlement and strict signature checks passed; this is not final notarization |
| CLI | Build 26 full verifier passed: JSON, concurrency, ownership, crash restart, rejected-state preservation and EFI recovery |
| macOS | Desktop observed; closing/reopening retained the same VM PID; graceful shutdown passed |
| Folder controls | Build 26 independent accessibility controls, read-only grant/removal and unchanged host file verified |
| Portability | 24 backend tests passed, including real ASIF history and historical ISO independence; build 24 GUI export hashes verified |
| Keyboard routing | Command bridge and release ownership corrected with native tests; ordinary typing remains deferred |
| Test cleanup | Old build caches and disposable test copies removed; retained installers and reusable guests must not be deleted as generic temporary files |

## Materials index

Paths under /private/tmp are temporary, not durable backups. Verify existence before resuming; preserve needed fixtures before OS cleanup. Do not commit guest disks, installers, credentials, certificates or provisioning profiles.

| Material | Location | Purpose |
|---|---|---|
| Acceptance requirements | docs/implementation/UNIFIED_ACCEPTANCE.md | Required gates and scoped exception |
| Detailed history | docs/implementation/PROGRESS.md | Dated test observations and limitations |
| Known issue | docs/KNOWN_ISSUES.md | Deferred Omarchy input issue |
| Product plan | docs/RIFTVM_UNIFIED_PRODUCT_PLAN.md | Agreed product scope |
| Final-candidate archive (local) | /private/tmp/riftvm-candidate26/RiftVM-0.1.0.zip | Signed build 26; not final-release approved |
| CLI evidence (local) | /private/tmp/riftvm-candidate26/cli-acceptance.log | Successful build 26 CLI run |
| Installed App (local) | /Users/eevv/Applications/RiftVM.app | Build 26 at last verification |
| Omarchy guests (local) | /Users/eevv/RiftVM Virtual Machines/ | New, Fresh and incomplete Clean test workspaces |
| macOS guest (local) | /private/tmp/riftvm-candidate7/MacOS-Speakers.riftvm | Existing installed guest; owner knows its login |
| Rollback guest (local) | /private/tmp/riftvm-candidate7/Omarchy-Rollback.riftvm | Retained recovery fixture; disk rollback not yet proven |
| Debian GUI guest (local) | /private/tmp/riftvm-live-acceptance/Build4-GUI-Debian.riftvm | ISO installation/login evidence |
| Debian CLI base (local) | /private/tmp/riftvm-candidate9/Debian-DiskOnly.riftvm | Copy for isolated CLI verification |
| Debian ISO (local) | /private/tmp/riftvm-debian-13.6.0-arm64.iso | Reuse for generic ISO tests |
| macOS installer (local) | /private/tmp/riftvm-macos-26.6.2.ipsw | Retained guest installer; host minimum remains macOS 27 |
| GUI export (local) | /private/tmp/riftvm-candidate7/Build24-Portability.riftvmexport | Validated no-history export fixture |
| Related repositories (local) | /Users/eevv/github/products/riftvm/ | riftvm, riftvm.github.io, riftvm-omarchy-aarch64-image, homebrew-tap, .github |

## Resume notes

Start with R01, then R02–R09. Reuse existing evidence where valid; rebuild only for changes that require it. Submit notarization only for the selected final candidate. Do not ask the owner to perform ordinary debugging, testing, temporary-guest setup or process recovery that is already authorized.

Last observed before the pause: Omarchy New and MacOS-Speakers were running after a mixed restore attempt. This handoff did not recheck or terminate them; inspect current runtime state before replacing or killing the App. No completed mixed-restore pass is claimed.

There is no immediate request for owner action. When resuming, useful owner-provided context is domain-provider information and any additional reproduction material. Existing login or account interaction is conditional, not a prerequisite for all remaining work. Never place passwords in Git.
