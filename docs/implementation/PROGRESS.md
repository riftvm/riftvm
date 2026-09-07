# RiftVM 0.1.0 implementation and verification record

Updated 2026-09-06. This is an in-progress record, not a release acceptance certificate.

## Current milestone

- Imported the complete tracked EZVM baseline in commit 7472ab2. Original repositories have not been modified.
- Renamed App, package modules, CLI, source paths, Agent services and environment variables. App is com.riftvm.app, 0.1.0 (1), Apple Silicon/macOS 27, English-only.
- Moved Omarchy source into the main App target, Guest overlay to GuestResources/Omarchy, and inherited Omarchy tests to Tests/RiftVMAppTests. Archived the obsolete desktop project and resources as historical material.
- Added persistent UUID/profile/location registry and default launch routing. Corrupt registries do not silently reset. Duplicate identities are rejected; moved workspaces retain identity. Run leases use identity when present and canonical path otherwise.
- Added new workspace home, primary Omarchy/macOS creation, Custom Linux ISO entry, menu bar, reopen routing, Finder workspace type, and snapshot/settings links for standard VMs.
- Retain running windows/controllers when hidden. Unified quit transaction coordinates all participating VMs; timeout choices are wait, cancel, or explicit force stop. Added injected-participant tests for the transaction.
- Scoped Omarchy clipboard/microphone/notification preferences by workspace. Notifications carry workspace ID. Clipboard uses active display focus and provenance to avoid guest-to-guest forwarding, with cancellation/revalidation before Host publication.
- Added Omarchy CPU/memory choices. Added cancellable download/preparation and cross-process serialized shared factory cache. Factory cache files are read-only; writable workspace copies restore owner-write permission.
- Adapted CLI library discovery and runtime lock lookup to the new registry and identity. Full profile-specific command acceptance remains outstanding.
- Fixed an EDID regression caused by a longer brand string resizing the fixed 128-byte display descriptor.

## Evidence collected locally

Host: macOS 27.0 (26A5425a), Xcode 27.0 (27A5252f).

- Core tests: 390 cases, zero failures, one inherited skip. /private/tmp/riftvm-swift-test.log.
- CLI tests: 13 cases passed, including registered-external-directory discovery coverage.
- App tests: 56 cases, zero failures; includes migrated Omarchy checks and new quit/clipboard ownership tests. See /private/tmp/riftvm-app-tests.log and /private/tmp/riftvm-tests-derived/Logs/Test for xcresult evidence.
- Graphics tests: all 26 passed after EDID fix. /private/tmp/riftvm-graphics-test.log.
- Guest Agent: go test ./... passed. /private/tmp/riftvm-agent-test.log.
- New App launched using test virtualization entitlement, isolated RIFTVM_DATA_ROOT and GUI readiness probe. /private/tmp/riftvm-ui-ready.json records com.riftvm.app, responsive event loop and visible 1080x760 window. Inspected home screenshot and macOS creation accessibility tree through computer use. The online macOS catalog failed in that run; local IPSW and latest-compatible choices remained visible. No guest was installed or booted in this UI check.
- Developer ID Application certificate is available. GitHub CLI authentication works, the new App repository is public and image-repository Actions are enabled. No notarization or signed candidate was performed.

## Required remaining work (not waived by this milestone)

1. Complete and exercise actual lifecycle transitions: two Omarchy guests, mixed Omarchy/macOS guests, window close/reopen, defaults, error/offline routing, paused shutdown, and quit during install/creation.
2. Finish profile-specific CLI start/status/stop and import/export/duplicate semantics, including independent guest credentials and UUIDs. Do not infer full CLI support from list/inspect tests.
3. Complete explicit Omarchy host-directory read-only/read-write sharing, permissions and deletion safety. Validate focus loss/modifier release, background clipboard and notification routing against real guests; unit ownership tests are insufficient.
4. Adapt the image repository to RiftVM Agent/overlay and pinned source revisions. Build and validate a fresh ARM64 image. Convert/package/sign the immutable factory, configure real public-key trust and pin its published manifest. Current default factory URL still names a mechanically renamed legacy candidate and is not a valid release channel.
5. Consolidate release scripts and CI into one App path. Inherited scripts still contain obsolete second-App assumptions, release version/tag rules and 24-hour gates. Replace them coherently while retaining signature, notarization, integrity and functional gates. Old scripts are not ready for publication.
6. Build new icon and visual assets; old bitmap assets are still present. Create the new GitHub Pages website and organization profile. Create the approved homebrew-tap repository and one cask.
7. Restore and verify all existing storage/network/graphics capabilities from the new UI, including standard VM export/import and Omarchy recovery operations. Regression-test low space, cancellation, offline media, corrupt downloads and interrupted transactions.
8. Produce Developer ID-signed/notarized archive, Gatekeeper and archive round-trip evidence, CLI/cask checks, and public-download clean installations of Omarchy/macOS on this Mac. Required evidence must match the shipped App/Agent/factory revisions.
9. Configure/verify default GitHub Pages deployment and downloads. Owner-managed riftvm.com DNS is pending; do not claim domain launch. Long soak/sleep certification remains explicitly deferred and must not be advertised as passed.

## Practical continuation notes

Main checkout: /Users/eevv/github/products/riftvm/riftvm. Original /Users/eevv/github/products/misc/ezvm is read-only reference for this task.

Current single scheme is RiftVM, with RiftVMAppTests hosted by RiftVM.app. Test signing overrides must use scripts/virtualization-test.entitlements; ad-hoc signing with distribution USB/vmnet entitlements was rejected by macOS. Use the user's Developer ID for release checks.

Image migration is now in progress. The old local integration branch (1771f5c) was stale; the remote integration branch is 6aa7490b3cafa417dbb269e524d886fc4bfca29d, containing later owner-provisioning/clipboard implementation. Fetch that exact reference into the new image repository, use its complete source, then apply the new identity and pin the new Agent revision before enabling a build. Do not modify the old checkout.

## Image pipeline and explicit shutdown follow-up

- Migrated the complete image integration from 6aa7490b3cafa417dbb269e524d886fc4bfca29d. New image commit 548fcc5 pins App/Agent 1fa95a0de6d0478d2d098321f8d5b2ec929ce5b5.
- Linux ARM64 image contracts passed in GitHub Actions run 34089893327, including display watcher and owner provisioning. Removed duplicate CI and fixed the renamed enrollment mount contract.
- Full native image build started as run 34089946830 with tag v0.1.0-rc.1 and publish_release=false. Inspect this existing run; do not dispatch a duplicate. The candidate must remain draft until factory conversion/trust and actual guest acceptance.
- App and CLI raw-image manifest kind is com.riftvm.preinstalled-image, matching the new image packager.
- Omarchy Stop/Restart timeout now asks Wait or Force Stop; elapsed time alone never authorizes force stop. Paused guests resume before graceful shutdown so they can process the request. App tests pass; real guest verification remains required.

## Workspace folder permissions

- Added per-workspace FolderGrants.json with explicit read-only (default) / read-write VirtioFS grants. Native Folder Permissions UI only permits changes while stopped and prevents overwriting unreadable permissions. Removing a grant preserves the host directory. Missing directories block startup with an actionable error.
- User grants use a separate riftvm_folders device, preserving the authenticated Agent transport share. Image commit 935a1b0 adds an on-demand mount and non-destructive ~/Mac link. This image change is not present in the previous build attempt.
- Two focused Core tests passed for actual VZ share configuration, persistence, revocation without deletion, absent directories and corrupt permissions. All 56 App tests passed. Real Guest read/write enforcement and filesystem behavior remain required.
- Image run 34089946830 is terminal FAILED: upstream Hyprland/Hyprtoolkit require libaquamarine.so=13-64 unavailable from the current signed/official package combination. Do not rerun unchanged inputs. Investigate matching package snapshots or digest-pinned integration rebake from the known-good previous image, with provenance retained.

## Pinned base migration investigation

- Confirmed public EZVM .32 base raw SHA-256 1ad443730ea340eaa7003b01c26ea142434b0f88a4280bd34fb8909e32d9b0a9. Its Omarchy and wl-copy pins match current sources. This is a factory build input only; there is no user-workspace migration promise.
- Image repo commits ad79deb and 7255538 add explicit fixed-base reconstruction, preserving part/archive/raw verification and normal new-format rejection of legacy headers. Also corrected remaining run-rift escaped systemd unit references in build-image.
- Active read-only Linux inspection run: 34090810766 (Inspect pinned migration base), confirmed downloading/verifying as of 2026-09-06 23:28 local. Download its migration-inventory artifact once complete to determine all old integration paths before implementing migration. No rebake has run.
- Local original base download is running under exec session 71212 into /private/tmp/riftvm-base-provenance. It contains the original release manifest and provenance already; poll this same session rather than starting a duplicate download. Required download is ~3.1 GB sparse archive, complete disk logical size 64 GiB.
- Source CI for ad79deb failed only in a newly added sparse fixture (missing extent separator); corrected fixture in 7255538, locally decoder-checked, new CI pending. Existing reconstruction/integration/folder tests passed before the fixture.
