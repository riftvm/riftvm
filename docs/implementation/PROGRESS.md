# RiftVM 0.1.0 implementation progress

Status: implementation and release acceptance in progress. No public App release is available. Passing individual checks below does not establish completion of the [implementation plan](../RIFTVM_IMPLEMENTATION_PLAN.md).

## Implemented

- Copied and adapted reusable EZVM source into the new repositories. Original repositories and user workspaces are untouched.
- Unified native App, new English workspace library and creation flow, RiftVM identity, version 0.1.0, bundle identifier com.riftvm.app, new icon and website.
- UUID workspace registry, ownership leases, independent disks and credentials, resource admission, default routing and persistent window ownership.
- Per-workspace clipboard, notification and microphone preferences; explicit read-only/read-write folder grants with stopped-only editing and fail-closed validation.
- Coordinated quit with save where supported, otherwise graceful shutdown and explicit timeout choices. Live runtime errors do not automatically terminate a Guest.
- Omarchy CLI routing, authenticated shutdown, image trust, shared factory cache and independent writable workspaces.

## Verified development behavior

- App integration suite: 56 tests pass after the latest lifecycle fixes. Earlier Core, CLI, graphics and Agent test milestones remain development evidence; final candidate checks must be rerun as required.
- Real Omarchy first-user provisioning, authenticated Agent readiness, internal folder roundtrip, text/PNG clipboard roundtrip, file import, dynamic display, complex-password lock/unlock and fullscreen entry/exit.
- Closing an Omarchy window retains the running VM. Status-bar reopening still needs direct acceptance.
- Two independent Omarchy workspaces run in the same GUI process. Pausing one leaves the other running, and library status now updates from VZ state observations.
- Unified quit succeeds with both Guests running and with one running/one paused. The paused path now resumes Agent integration and waits for fresh authenticated status before shutdown. Timeout Wait/Cancel/Force Stop remains explicit; no automatic force stop was introduced.
- These checks do not establish multi-Guest focus/clipboard/notification isolation, user-folder access enforcement or snapshot recovery.

## Image and website

- Image source CI passed in [run 34091337579](https://github.com/riftvm/riftvm-omarchy-aarch64-image/actions/runs/34091337579).
- Draft factory build [34091423206](https://github.com/riftvm/riftvm-omarchy-aarch64-image/actions/runs/34091423206) succeeded from a verified pinned base and current overlay. Upstream package drift prevented a fresh package-graph build; provenance preserves the original package base.
- Candidate raw SHA-256: `99714624832d5fabaae59f58ad8f657384ebbfcf17ae5a72172b66c79965a000`. Agent revision: `1fa95a0de6d0478d2d098321f8d5b2ec929ce5b5`.
- New Ed25519 factory trust, ASIF byte comparison, multipart signing and signature verification succeeded. The verified image is now available as [v0.1.0-rc.1](https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/tag/v0.1.0-rc.1), a prerelease that does not replace latest. Public cold download and development profile pinning passed; final signed-App acquisition is still pending.
- [Default Pages site](https://riftvm.github.io/) is deployed, English-only, and accurately says the App is in development. Desktop/mobile layout and navigation checked. The verified Linux installer catalog is served there. Custom domain DNS remains unconfigured.
- Organization profile and Homebrew tap repositories exist. No unverified cask has been published.

## Internal signed candidate

- [Main source CI 34097355417](https://github.com/riftvm/riftvm/actions/runs/34097355417) passed Agent race tests, shell syntax and Xcode 27 compile checks. Hosted compilation does not replace macOS 27 runtime acceptance; see [CI scope](CI.md).
- Source-built VirGL runtime, Developer ID archive/export, nested signatures and production entitlement checks succeeded.
- Internal candidate: version 0.1.0, build 1, clean source `62a0eefd57727b278970e743d9febd4212f5f1b0`.
- ZIP SHA-256: `f9800998e7a5c8fe27586d2731ae9cd351071019e5ce92b0f7811d360b834265`.
- Apple notarization returned Accepted. Exact ZIP extraction passed strict signature, entitlement, source/version and Gatekeeper checks. Normal GUI launch and embedded CLI doctor succeeded.
- This candidate is not published or functionally accepted. Signed Guest boot, public factory acquisition, offline/stapled assessment, cask installation and final release evidence are still pending.

## macOS installation acceptance

- Official Apple restore image 26.6.2 / 25G83 downloaded and verified. SHA-256: `885503b7f4b06609e9a512f2befd40f59730640a3f1233e3892d60affdd51c95`.
- Apple native inspection confirms hardware compatibility, and latest-compatible lookup returns this same image. Earlier standalone-tool connection failures were missing test entitlements, not an Apple service outage.
- Signed App local-IPSW selection and workspace naming/location steps were exercised. Resource-page UI automation hit a crash in the automation service; RiftVM remained live. Installation has not started and is not claimed as passed.
- Online catalog empty-result wording and current built-in version metadata still need refinement.

## Required next gates

1. Complete real macOS and Custom ARM64 Linux installation and recovery checks.
2. Verify two-Guest and mixed-profile input, clipboard, notification and folder isolation.
3. Complete snapshot/rollback, duplicate identity, portability and signed CLI lifecycle checks.
4. Consolidate remaining legacy release scripts around the one App and carry the validated factory pin into the final signed candidate.
5. Rebuild and validate the exact final signed candidate, publish accepted artifacts, verify public cold installation and the Homebrew cask, then update download documentation.

Long soak and sleep/wake certification remain explicitly deferred. All other required completion gates remain in scope.

## Catalog and unified release-script refinements

- macOS empty catalog responses now have a distinct message; they are not reported as network failures. Added the Apple-verified current restore image, full digest/size, and version/build fields for deterministic built-in release ordering. Empty cache contents no longer suppress a retry. App build and 56 integration tests passed.
- Release builds accept RIFTVM_BUILD_NUMBER and pass it into both archive and build paths. Metadata verification rejects invalid/mismatched build numbers. Signed archives now honor the requested isolated derived-data directory. Metadata and signing-preflight regression checks passed.
- The unified build now verifies the pinned factory public key, compiled icon representations, source metadata and unified production entitlements. Tampered identity, factory trust, missing icon/assets and extra entitlement fixtures are rejected. The existing notarized internal candidate passes these checks.
- Standalone Omarchy build/publish entry points are retired and fail before creating state. The remaining general publisher still needs full unified functional-evidence integration before it is used for a public release.

## Native installer and signed runtime checks

- The notarized internal candidate completed a real macOS installation using the App's existing native installer acceptance entry and the verified Apple IPSW. Installation reached 100% and returned success. This exercises the GUI's underlying installer; GUI completion and Guest desktop setup remain unverified.
- The signed CLI concurrently ran macOS and a restored Omarchy workspace, rejected duplicate starts, and normally stopped Omarchy without stopping macOS. macOS graceful stop timed out and is not claimed as passed.
- A deliberate crash-recovery test initially hit a transient auxiliary-storage lock when immediately restarting macOS. Restart succeeded after the lock released. Immediate post-crash recovery still needs refinement/verification.
- Protected Omarchy snapshot/marker restoration passed, followed by signed runtime startup. Guest-filesystem mutation/rollback proof still remains.
- Official Debian ARM64 ISO download and digest verification passed. The signed App created its ISO-backed test configuration and reached VM running state; Linux installation and desktop interaction are not yet complete.

- Ordinary macOS/Linux stop requests now resume a paused VM through the shared resume lifecycle before requesting guest shutdown. App build and 56 tests pass. This code correction is separate from the observed running macOS shutdown timeout; paused standard-Guest behavior still requires real runtime verification.

- Omarchy protected-backup and restore actions now hold the shared maintenance lease until background disk work completes. A competing GUI or CLI start is rejected during these actions, and both success/failure paths release ownership. App build and 56 integration tests pass; real concurrent recovery acceptance remains pending.
- Standard workspace close delegates hide and retain their windows. The older save/stop callback belongs to view-controller dismantling, which normal close does not invoke; this audit does not replace direct standard-Guest close/reopen acceptance.

- Initial Omarchy installation, migration, interrupted-recovery repair and preserve/reinstall now acquire the same maintenance ownership as runtime startup. The lease spans asynchronous work and is released on completion or failure. App build and 56 integration tests pass.
- Native Apple validation accepts save/restore for the current complete Omarchy configuration. The existing fixed unsupported flag is therefore incorrect; actual Omarchy session save/restore integration is now a required remaining correction. No successful saved Omarchy session is claimed yet.

## Omarchy saved-session correction

- Replaced the fixed unsupported flag with native configuration validation and runtime capability checks. Unified quit now saves supported Omarchy workspaces and waits until their session transaction commits before allowing process exit.
- Saved sessions include a compatibility record for effective CPU/memory/microphone configuration, host version, workspace/hardware identity, disk size/modification state, directory grants and snapshot metadata. Changed or interrupted sessions remain available until the user explicitly chooses to discard guest memory and cold start; guest disks are preserved.
- Real development-runtime save/stop/restore passed from both running and paused states. Real App termination through the unified quit coordinator also passed from both states, followed by successful restoration. Each roundtrip preserved the guest boot ID, reauthenticated the Agent and then shut down normally.
- A first quit acceptance attempt deadlocked because the test invoked AppKit termination inside a main-queue task. Process sampling identified that cause; the disposable test was ended, the hook was moved to the AppKit event loop, and both quit roundtrips then passed. That failed attempt is not counted as successful acceptance.
- These are development-build checks, not final signed-candidate approval. Multi-workspace save transactions, failure-path runtime acceptance and exact final artifact checks remain required.

- Latest App build and integration suite: 59 tests pass, including saved-session commit/consume, interrupted transaction preservation, and rejection of changed disks, identities, folder permissions, resource allocation and truncated memory files.

## Public factory acquisition

- Main saved-session source CI [34104010780](https://github.com/riftvm/riftvm/actions/runs/34104010780) passed. Image pipeline/documentation CI [34104419888](https://github.com/riftvm/riftvm-omarchy-aarch64-image/actions/runs/34104419888) passed after removing premature raw-only publication and old installation claims.
- Published only the verified image prerelease, not the App. Its public manifest exactly matches the signed draft bytes and every uploaded part's digest and length. Complete ASIF SHA-256: `be656562670112c480b0ce14b12ff229af5d828268c289bfea9e18eb1a8d94ce`.
- The App's native factory downloader completed a real public download into an empty cache with no GitHub token. It verified all 5,286,920,192 bytes and published a read-only image. A warm acquisition revalidated and reused the same file without modifying it.
- A fresh workspace created from that downloaded image completed native first-owner configuration, authenticated Agent/desktop readiness, session save and restore, and normal shutdown. Restoring preserved the Guest boot ID. Automatic clipboard/display/shared-folder probes were interrupted by the deliberate save and are not claimed as passed by this check.
- Production profile now pins the exact public candidate URL. App integration tests (59), profile tests (4), factory installer tests (10), and existing factory-tool signing/tamper regression checks pass. The new download command exercises the same installer as the App; it does not replace creation-GUI or final signed-candidate acceptance.
- The two-stage procedure is documented in [FACTORY_RELEASE.md](FACTORY_RELEASE.md).

## Native directory-grant enforcement

- Added an opt-in acceptance probe restricted to temporary workspaces and temporary explicitly granted directories. It uses authenticated Agent file transfer against the actual VirtioFS mount.
- Real Guest reads passed for both a read-only and read-write grant. Guest-to-host writing passed for the writable grant. The read-only grant rejected a new file with `operation not permitted`, and a subsequent read succeeded with no write published on the host.
- The initial probe expected only a read-only-filesystem error and failed. Diagnostic remeasurement identified the actual per-directory EPERM result; the corrected probe retains that reason and still requires the writable companion and post-denial read to pass.
- Temporarily disconnecting a granted test directory caused native startup to fail with a specific unavailable-folder error. The directory was restored and original host marker contents remained intact.
- App build and 59 integration tests pass. These checks do not establish GUI grant removal, cross-workspace folder visibility or the broader input/clipboard/notification isolation gates.

## Directory-grant removal and rollback verification limits

- Folder-permission edits now acquire the workspace maintenance lease through persistence, preventing competing startup during the change.
- Removing a grant through the real persistence API, then restarting the Guest, made its former mount path absent while the remaining writable grant still passed authenticated read/write checks. Original host files were preserved. The GUI removal interaction itself remains pending.
- A Guest disk rollback probe could not establish persistent mutation: the Agent has a private temporary namespace and the image service exposes system directories read-only. The unsuccessful probe was removed without weakening these restrictions. Protected snapshot creation/deletion rejection was exercised, but Guest-filesystem rollback remains unverified and required.
- After removing that probe, the App build and 59 integration tests pass.

## Notarization receipt validation

- The unified publisher no longer accepts an empty notarization marker. It requires a structured Apple Accepted response with a submission identifier and a digest matching the exact archive before reusing notarization state. Missing, malformed, rejected and stale receipts fail validation.
- Regression checks cover accepted and rejected results, missing identifiers, legacy empty markers and changed archive bytes; these checks also run in source CI. The existing internal candidate's actual accepted response and archive pass the same validator. This does not qualify that older candidate for final release or resolve offline Gatekeeper and unified functional acceptance.

## Homebrew template correction

- Removed the stale installable Cask from the main source tree. The publisher now generates a Cask from an explicit template using the requested semantic version and actual archive SHA-256, and creates the destination Casks directory for the new tap. Invalid versions or malformed templates fail before changing output.
- Installer and verification defaults now use `riftvm/tap/riftvm`. The template uses the organization release URL and current Pages website.
- The installed Homebrew parser rejects a macOS 27 dependency enum, so the template uses a macOS-only dependency plus an explicit minimum-major-version preflight check. Homebrew parses the generated candidate successfully, with a deprecation warning for the preflight DSL. Generation and malformed-input rejection checks pass. Actual tap installation and final candidate verification remain pending; no Cask was published.

- Executed the actual generated Cask's preflight through Homebrew with simulated host versions: macOS 26 is rejected; 27 and 28 pass. This check is reproducible with `brew ruby scripts/test-cask-preflight.rb` and does not install any artifact. The preflight deprecation remains a compatibility follow-up, not an ignored lower-OS admission failure.

## Native macOS saved-state correction

- A fresh native macOS installation completed successfully. The first strict save/restore test saved successfully but Apple restore returned invalid argument and the App cold-booted. This failed roundtrip is not counted as restoration.
- Standard macOS network configurations inherited Apple's random default MAC address on every launch. Network addresses now derive from the persisted machine identifier and adapter index, retaining locally administered unicast semantics.
- Successful restore now enters the same startup-completion handling as cold startup, including acceptance dispatch and headless service policy. Acceptance reports restored-and-stopped distinctly; the machine-state verifier rejects a cold-boot fallback.
- With these changes, real macOS save and cross-process restore passed, both processes exited successfully, and the committed saved state was consumed after restore. App build and 59 integration tests pass. This verifies native development-runtime state restoration, not Guest desktop setup, paused/unified-quit behavior or the final signed candidate.

- A second native macOS roundtrip invoked the actual pause action, waited for paused state, then saved and exited. The next process restored successfully and consumed the committed state. The formal machine-state script now requires both running and paused save/restore roundtrips on a temporary clone. App build and 59 tests pass; unified Quit and final signed-candidate acceptance remain separate.

- Native macOS unified App termination now has real acceptance evidence from both running and paused states. Each test invoked AppKit termination through the actual quit coordinator, exited successfully with a committed saved state, then restored in a new process and consumed that state. The opt-in hook is restricted to temporary fixtures and does not call Save directly. App build and 59 integration tests pass. Multi-workspace quit, GUI interaction and final signed artifact verification remain pending.

## Multiple macOS workspaces on unified quit

- Added an opt-in acceptance peer using a distinct temporary standard workspace in the same App process. Quit is requested only after the primary and peer are both running.
- The first attempt hit the host active-VM limit. Earlier disposable processes were explicitly ended for test cleanup with disks retained; that cleanup is not a graceful-shutdown success.
- The next attempt committed both memory files, but restoration detected disk changes after saving. Standard saved-state metadata was being committed before native stop flushed and released disk attachments. The transaction now commits after successful stop and device release; stop failure discards only the pending transaction, while commit failure reports that the VM has stopped.
- With corrected ordering, both same-process macOS VMs saved on unified App quit, the App exited successfully, and both states restored in separate new processes and were consumed. Prior failed-attempt state was retained as private diagnostic evidence. App build and 59 tests pass. Mixed Omarchy/macOS quit, GUI interaction and final signed-candidate verification remain required.

## Mixed-profile unified quit

- The temporary peer acceptance now supports the real Omarchy runtime view as well as standard Guests. Runtime readiness is checked through the same coordinator registration used by unified Quit.
- A macOS and Omarchy VM ran in one process; unified App termination completed with both saved sessions present. macOS restored in a new process and consumed its state. Omarchy restored through its saved-session path, reached authenticated integration readiness, saved again and exited normally. Omarchy does not silently cold-boot on a failed saved-session restore, so a failed native restore cannot satisfy this check.
- App build and 59 integration tests pass. These are native development-runtime checks; UI operation, broader cross-workspace isolation and final signed artifact verification remain pending.

## Signed-candidate restore investigation

- Developer ID build 2 passed archive signature, identity and entitlement checks, but two independent macOS fixtures failed native restore with permission denied. Diagnostic build 3 reproduced this. Virtualization service logs identify a Secure Enclave decryption failure with interaction-not-allowed status; an unlocked interactive host session still needs confirmation before attributing this to signing. These candidates are not release-approved.
- Native restore errors now preserve committed guest memory instead of deleting it and silently cold-booting. A temporary corrupted-header test caused actual Apple restore rejection and headless failure; memory and compatibility manifest remained byte-identical. The valid test checkpoint was restored afterward for retry. App build and 59 tests pass.
- Apple notarization upload is awaiting explicit user confirmation after automatic approval review rejected that export. GUI automation remains unavailable. Neither condition is treated as a successful acceptance gate.

## Build 4 notarization

- After explicit authorization, the signed 0.1.0 build 4 from source `a909718` was submitted to Apple. The archive contains the App bundle and macOS archive metadata, with no Guest disks or installers.
- Apple returned Accepted, submission `ba047a1b-d087-40c2-abd8-c3f13d0d805f`. The structured receipt passed exact-archive SHA-256 verification. The extracted App passed Gatekeeper assessment as Notarized Developer ID.
- This resolves the notarization authorization blocker. The candidate includes the new rift icon; its preceding App build and 59 integration tests passed. Real signed-candidate Guest restoration, GUI and remaining release acceptance still need completion; notarization alone does not authorize a release-ready claim.

## Build 4 native GUI creation smoke

- Native UI automation became available again. The notarized build 4 was running from its extracted candidate bundle, and its version, build, clean source revision and production entitlements passed verification.
- Through the actual five-step creation wizard, selected the existing ARM64 Debian ISO, named a disposable workspace, accepted the resource configuration, skipped folder sharing and created the workspace. Its persisted configuration contains no shared host directories, a 64 GiB ASIF disk, 4 GiB RAM and NAT networking.
- Run Virtual Machine displayed the real GRUB installer menu. Keyboard selection booted the graphical Debian installer to its English language page.
- Closing the VM window left the workspace marked Running in the control center. Reopening returned to the same graphical installer page. This verifies window close/reopen behavior for this signed candidate; it does not yet prove a completed Debian installation, menu-bar reopening, or other Guest profiles.

## Build 4 macOS state verification retry

- The full signed-bundle verifier passed factory trust, compiled icon representations, metadata, production entitlements and strict nested signatures.
- Retried the standard machine-state verifier on its disposable clone. The running-state save completed, but cross-process restoration did not report `restored-and-stopped` within 120 seconds. This is a failed acceptance check, not proof of successful restore or evidence of the earlier permission-denied cause.
- The verifier terminated its Launch Services waiter but left the disposable App process running; explicit process cleanup was required. The verifier needs stronger child-process cleanup and retained timeout diagnostics before another retry.
- Debian GUI installation reached account password setup and remains waiting for user handoff. The signed CLI validated its configuration with no problems and reported it running.

## Machine-state verifier isolation and cleanup

- Added per-launch PID reporting with a fallback restricted to the exact executable and unique acceptance result-path environment token. Cleanup checks PID identity, samples failed processes, terminates only the disposable test process, and retains failed fixtures and logs. Successful-result exit waits are bounded.
- Exercised a real startup timeout: the fallback captured a stack sample and removed the test process while the independently running Debian GUI process remained alive. Symbolication identified `WorkspaceCoordinator.open` from the normal ContentView launch route blocked in `NSAlert.runModal`, rather than an established native restore hang.
- Added an isolated data root to prevent normal default-workspace routing from interfering with acceptance. With the unchanged notarized build 4, save succeeded and restore now promptly reported the native permission-denied failure. The committed state and detailed error were retained. This restores useful failure reporting; the macOS restoration gate is still failing.
- Shell syntax and diff checks passed. No signed App bytes changed in this verifier-only fix.

## Host lock-state evidence for build 4 restore

- The isolated retry's Virtualization service log records Secure Enclave decryption failure with OSStatus -25308 and AKSError -536870174 at the restore failure.
- A subsequent read-only IORegistry check explicitly reported `CGSSessionScreenIsLocked = true` while the console session was logged in. GUI automation availability therefore was not evidence of an unlocked host.
- This supports a host-lock explanation, but does not prove restoration succeeds after unlocking. Keep the failed saved-state fixture intact and require an unlocked-host retry before deciding whether further runtime or signing changes are needed. No security settings were changed.

## Unlocked-host build 4 state acceptance

- After the user confirmed unlocking the host, the isolated verifier passed all four actions with the unchanged notarized build 4: save while running, restore in a new process and stop, save after pause, restore in a new process and stop. Both restored checkpoints were consumed, and the verifier exited successfully.
- This confirms the signed candidate's running/paused macOS state roundtrips on the unlocked host. The preceding locked-host failure remains useful negative evidence; it is not a reason to weaken signing or security controls.
- The user completed Debian account password setup. GUI installation proceeded through timezone and guided partitioning of only the new 68.7 GB VirtIO test disk; the installer ISO was not selected for formatting. Installation and reboot acceptance remain in progress.
- The Debian installer text is visibly small on Retina displays. The Apple graphics backend enables automatic display reconfiguration; installer scaling needs a focused usability fix and verification.

## Linux installer display sizing

- Linux workspaces with installation media now keep their configured Apple Virtio display resolution instead of automatically matching Retina backing pixels. Display refresh preserves this policy. macOS and normal Apple-backed desktop display behavior remain dynamic.
- Added a regression test that exercises backend selection and refresh for a Linux installer and a macOS desktop. The App build and all 60 integration tests passed.
- This change still needs a visual installer check in a newly built candidate; the already-running build 4 cannot reflect changed code. The final signed candidate must be rebuilt and notarized after this change.
- The Debian installer completed and the Guest subsequently displayed its installed Debian GNU/Linux 13 console login prompt. Login/session checks and installer-media removal are not yet verified.

## Build 5 local acceptance

- Build 5 from `aefa609` passed signed archive extraction, factory trust, compiled icons, metadata and strict signature verification. Its App-only ZIP excludes Guest disks and installers.
- On the unlocked host, the exact extracted signed candidate passed running and paused macOS save/cross-process-restore roundtrips.
- A new 1280×720 Linux installer fixture booted the Debian graphical installer in build 5. Visual inspection confirmed readable larger text and visible navigation controls, replacing the tiny Retina-sized installer presentation seen in build 4. The display-test VM was paused after inspection.
- The user's screenshot separately confirms successful login to the installed build 4 Debian guest and execution of `uname -a` as the test user.
- Build 5 Apple notarization upload was rejected by automatic approval review, including a retry supplying previous authorization context. A specific build 5 upload confirmation is pending; no upload was bypassed or performed.

## Window toolbar overlap fix

- The standard Guest view no longer ignores the toolbar safe area. Only its black background extends beyond the content area; the window no longer forces transparent full-size titlebar content.
- App build and 60 integration tests passed. A separate real Linux installer fixture in the updated development build showed the toolbar in its own top strip and Guest output below it. This verifies windowed presentation; full-screen transitions and the final signed candidate still need validation.
- The user reiterated authorization for the pending notarization operation. A further App rebuild is required to include this newly requested layout fix before final distribution acceptance.

## Full-screen follow-up

- Used the native green window control to enter full screen in the toolbar-fix development build. The captured image showed white top/right edges. The Guest display itself remained visible; full-screen visual acceptance is not yet passed.
- Reintroducing full-size content while retaining Guest safe areas did not remove the observed edges. That experimental line was reverted rather than retaining an unverified fix. Both builds passed the existing 60 tests, illustrating that these tests do not establish full-screen visual correctness.
- The next diagnostic must distinguish actual window/content geometry from screenshot capture boundaries before changing layout further. The original windowed toolbar-overlap correction remains committed.

## Build 6 notarization

- Built signed 0.1.0 build 6 from `d20c217`, including the installer display and windowed toolbar fixes. Archive payload inspection excluded Guest disks and installers.
- Following the user's explicit response authorizing the pending Apple upload, automatic review allowed submission. Apple Accepted submission `4100a3f0-3c2d-41c1-a9b1-d50c5058d953`; the exact-archive receipt verifier and extracted-App Gatekeeper assessment passed.
- Build 6 is a candidate, not a completed release. Full-screen visual behavior and the remaining functional/distribution gates still require verification on the final artifact.

## Build 6 macOS runtime and restore portability

- The exact notarized build 6 passed running/paused macOS save and cross-process restoration on an isolated clone.
- Exported a stopped macOS fixture clone through the signed App's real portability implementation, validated the export in another process, and restore-imported it in a third process. All reported success, and the imported MachineIdentifier matched byte-for-byte.
- A fresh clone of that imported workspace booted and passed both running/paused save and cross-process restore checks. This proves restore-import runtime usability for this macOS fixture; it does not cover fresh-identity duplication or Linux Guest integration portability.

## Independent-copy data preservation and UI acceptance

- Exposed the standard-workspace export and new-identity import routes in the new library. Added visible busy feedback and disabled repeat portability actions while a copy is running; moved the platform caption onto its own line.
- A new regression test reproduced copied `Workspace.json` UUIDs colliding in the registry. Clone and copy-import now regenerate the workspace UUID while preserving its profile; restore-import retains identity. The original and imported modern-format workspaces were both registered through the native UI, with distinct on-disk UUIDs and machine identifiers.
- Real GUI startup exposed a more serious inherited portability defect: deleting the entire `Snapshots` directory removed active ASIF layers containing the installed operating system. Merely starting the VM and saving/restoring its framework state had not detected the resulting empty-disk guest. Prior fresh-copy lifecycle success must not be interpreted as successful OS boot.
- Independent copies now discard historical snapshots while retaining the current disk layer chain and its state. Missing, corrupt, or invalid active-layer references fail the staging transaction. Regression coverage verifies both clone and copy-import retain active disk bytes, remove old histories, preserve the source, and roll back incomplete chains.
- Related Swift suites: 80 tests, one skipped, zero failures. Updated App build and 60 integration tests passed. Through the actual new import UI, the original complete export produced `Complete-Layer-Copy.riftvm`, retained its 23 GB active layer, and booted to the macOS Hello/setup screen. This establishes guest OS boot after copy; completed Setup Assistant and desktop integration remain separate gates.
- The complete import visibly displayed its busy indicator and disabled duplicate import actions. The native export route also completed successfully in the current development UI.
- Full-screen diagnostics on both displays reported matching 1920x1080 window, hosting, and framebuffer bounds with zero safe-area insets. Captured white top/right edges persisted for Linux and macOS. A black display-layer experiment did not improve them and was removed, together with temporary diagnostics. The cause and full-screen visual acceptance remain unresolved.

- Follow-up on the now-bootable copied guest: selecting Save State and Stop from its full-screen window failed with `Could not pause before saving: Internal Virtualization error. The virtual machine stopped unexpectedly.` No saved-state file was produced. This development-build lifecycle result is a failure, not covered by the earlier framework-only roundtrip checks; reproduce with the current signed candidate and a booted guest before release. A later captured frame no longer showed white margins, but followed this failure and cannot establish healthy full-screen operation.

## Booted macOS audio/lifecycle comparison

- Reproduced the full-screen save failure with the notarized build 6, using a complete isolated clone of the installed macOS fixture. The original development failure's Virtualization service report recorded GUARD/SIGKILL termination after CoreAudio proxy errors; this is evidence of a service failure, not proof of its cause.
- In windowed mode, the microphone-and-speakers configuration paused successfully, saved/stopped, and restored in a new signed-App process to the visible macOS Hello animation. Its subsequent full-screen save failed without producing a committed state.
- Separate no-audio and speakers-only clones both booted visibly and completed full-screen save/stop, each producing a 1,543,507,968-byte state plus a compatibility manifest. Microphone input is therefore the next isolation target; do not remove audio support or claim the microphone path fixed from these comparisons.
- Native automatic window tabbing combined the later test workspaces into the existing full-screen window. Its interaction with workspace window ownership needs review.

### 2026-09-07 — Explicit microphone permission and release capability

- Standard workspaces now default to speakers only. Adding microphone input requests host authorization explicitly; existing input configurations without authorization fail before VM creation with actionable Settings guidance. Linux and macOS creators and runners share this check.
- Added the Hardened Runtime audio-input entitlement and required it in the production signature allowlist. Apple documents this capability at https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.device.audio-input ; system consent is still required.
- Validation: application test run in `/private/tmp/riftvm-microphone-access.log` passed all 61 tests, including authorized, denied, restricted, and undetermined audio configuration cases. Entitlement plist lint, release verifier shell syntax, and diff whitespace checks pass.
- This repairs verified permission/configuration gaps; it does not establish that microphone-enabled guest pause/save is fixed. Signed build 7 is being prepared for actual runtime comparison. Fullscreen microphone lifecycle and final release acceptance remain open.

### 2026-09-07 — Keep workspace windows independent in full screen

- Set workspace NSWindow tabbingMode to disallowed before presentation. This prevents AppKit from automatically merging a newly opened workspace into another workspace's full-screen window, preserving individual close/reopen ownership.
- Build passed (`/private/tmp/riftvm-window-independence-build.log`). Native UI verification with two isolated temporary macOS workspace windows: A entered full screen; opening B produced a separate window with its own full-screen/minimize controls; Window menu listed A and B separately; returning to A retained its full-screen state. These guests intentionally failed the pre-start microphone authorization check, so this proves window behavior, not simultaneous running-guest isolation.
- Signed build 7 also demonstrated the actionable pre-start microphone permission error and visible Allow Microphone Access control. Automatic approval review blocked requesting host microphone access; explicit user confirmation is pending. No permission bypass was attempted.

### 2026-09-07 — Build 7 booted macOS speaker-only save/restore

- Signed build 7, isolated `/private/tmp/riftvm-candidate7/MacOS-Speakers.riftvm`, cloned from the stopped complete installed fixture with active disk layers retained. Speaker-only configuration booted to macOS Hello and then the Language page.
- Full-screen Save State and Stop succeeded: MachineState.vzvmsave 1,375,735,808 bytes with 884-byte manifest. Reopening through the app restored the Language page; after guest display reconfiguration the window showed the complete centered page. This demonstrates actual OS UI continuity for this speaker-only fixture.
- Full-screen capture still showed top/right white margins. Initial restore briefly showed the prior larger framebuffer cropped before adaptation. Display transition acceptance remains open; desktop setup and microphone-enabled lifecycle remain unverified.

### 2026-09-07 — Preserve unverified live CLI runtime records

- During cleanup, an older candidate headless process remained live but the newer CLI reported not_running because executable paths differed. The stop path also discarded its record.
- Start, status and stop now return process_ownership_unverified when a saved record points to an existing PID whose ownership cannot be verified by the current installation. They preserve the record, do not signal the process, and do not launch a replacement. Exact executable ownership checks remain intact.
- All 14 CLI tests pass, including a live unrelated-process regression that checks all three commands preserve the original state bytes.
- Cleanup removed 17 obsolete build/test directories and released approximately 7.4 GiB of actual space. Downloaded ISO/IPSW/factory images and installed base fixtures were retained. The obsolete headless test did not exit after its normal shutdown signal and was explicitly terminated; its disk was retained. Current GUI testing uses one fixed installation at ~/Applications/RiftVM.app (signed build 8).
- User completed Device Control and Data Access authorization; Omarchy permission banner disappeared. A normal stop/cold-start followed by existing-password login reached the desktop and authenticated text/image clipboard readiness. Guest-file rollback is still pending; automatic menu interaction has not yet provided reliable terminal access.

### 2026-09-07 — Signed build 8 window continuity and protected recovery

- Closed the running Omarchy-Rollback window through its native close control. The library continued to show Running. Reopened using Open Workspace; both the app PID (71251) and Virtualization service PID (72528) remained unchanged. The initially black guest display responded to input with its lock screen, consistent with guest idle blanking rather than a VM restart.
- The Recovery menu correctly disabled backup/restore while running. After normal Stop Omarchy, Create Protected Backup completed and the protected point appeared in the menu. Restored that point through the confirmation sheet and started the workspace again; the visible Omarchy login screen returned and Integration reported ready.
- This validates the native backup/restore/start path on an installed guest, but does not establish rollback of a subsequently modified guest file. That distinct data-continuity check remains open.

### 2026-09-07 — Preserve CLI test disks after failed shutdown

- CLI release verification previously deleted its temporary VM directory even when both cleanup stop requests failed. Cleanup now requires successful status responses positively reporting stopped for every clone before deleting any of them. Unknown ownership, a running state, failed responses and malformed JSON retain the entire directory and fail cleanup. Added regression coverage and wired it into CI.
- The signed build 9 Debian CLI run reproduced a real shutdown timeout after two concurrent starts. The corrected cleanup preserved both clones. After normal stop and cleanup retries did not terminate them, the two exact disposable runtimes were identity-checked and explicitly terminated; their disks and the failure log remain available. This CLI lifecycle gate has not passed.
- The frozen Debian fixture still includes its installer USB ISO and microphone input; installed-disk-only validation and the timing of shutdown during boot need investigation before attributing the timeout to application shutdown handling.
- Signed build 9 passed signature/metadata/resource verification and CLI doctor, consumed the prior Omarchy saved session, and reached its unlocked desktop with Integration ready. Foot terminal was opened through the guest menu, but automated text/key input was inconsistent and native paste timed out. No guest-file rollback success is claimed.

- Follow-up: a complete clone of the user-verified Build4-GUI-Debian workspace, with installer USB removed and speakers only, booted visibly to the installed Debian 13 console login under signed build 9. The native Shut Down action then returned the workspace to Stopped. This closes the installed-system/no-ISO GUI boot and shutdown check, but does not resolve the earlier headless timeout.
- The same installed-disk-only clone also completed a separate CLI start/stop roundtrip (runtime PID 75872), returning stopped successfully after allowing guest boot to progress. The original full concurrent CLI verifier remains a failed run; its log is preserved. Once both failed-run processes were confirmed absent, the guarded cleanup removed their disposable directories.

### 2026-09-07 — Concurrent fixture identity and headless stop retries

- Modern CLI smoke clones now receive distinct Workspace.json IDs. Previously both inherited the source ID and the registry correctly rejected the second concurrent VM. The source fixture is unchanged; the existing fixture guard regression now checks identity renewal.
- Standard headless guests now accept another explicit stop request after an earlier one timed out. The previous headlessStopRequested guard discarded all later signals, stranding guests that ignored a platform shutdown during early boot. Omarchy retains its in-flight transaction guard. No automatic force stop is added.
- CLI smoke checks retry once only for stop_timeout, exercising this recovery path without hiding other errors. Signed runtime verification is pending the next candidate build.

### 2026-09-07 — Signed build 10 complete Debian CLI regression

- Installed signed build 10 (source ab9026262d18dc8cc971438ac356a6fe5ca0b40e). Signature, production resources and metadata checks passed; that commit's GitHub CI also completed successfully.
- Full CLI verification against the installed-disk-only Debian fixture passed: JSON interfaces, two independent modern workspace IDs running concurrently, duplicate-start refusal, graceful-stop retries, restart after explicit SIGKILL, byte-identical preservation of rejected synthetic saved state, cold startup after explicit removal, and EFI variable-store recovery. Several early shutdown requests timed out; the later explicit retry succeeded without forced shutdown, exercising the repaired path.
- The verifier now follows the existing native-restore protection policy instead of expecting silent memory deletion. Updated the legacy-session notice and troubleshooting text to remove that stale promise. These wording changes are newer than the tested build 10; runtime preservation behavior was exercised in build 10.
- Evidence log: /private/tmp/riftvm-candidate10/cli-preservation-acceptance.log. The verifier exited 0, removed its disposable clone directory, and left no RiftVM or virtual-machine process running. Obsolete build 8/9 derived directories were also removed after checking for open files; archives and base images remain.

### 2026-09-07 — Keep the empty Mac folder mount available

- Signed build 10 guest Files reproduced a broken ~/Mac entry (No such device) while /mnt/riftvm-shared remained accessible. The desktop shortcut points at the optional host-folders VirtioFS tag, which the App omitted when no directory grants existed.
- Omarchy now always includes that device with an empty VZMultipleDirectoryShare when no grants exist. The SDK explicitly supports empty shares. No host directory is exposed by the empty mapping; missing/corrupt permissions still fail closed and removed grants still preserve host files.
- Added a saved-session directory-sharing layout version so checkpoints from the previous hardware layout are rejected and retained instead of sent to native restore as if compatible.
- Validation: seven Core builder/folder-grant tests passed. App build and targeted saved-session compatibility regression passed, including rejection and preservation of a manifest lacking the new layout version. Actual signed guest verification of the fixed Mac entry remains pending.
- A marker was created in the managed shared directory and read through guest Files. Guest-home copy and file rollback are not yet verified; a text preview of the shared original is not evidence of a guest-disk write.

### 2026-09-07 — Build 11 runtime and distinct recovery labels

- Signed build 11 from 45facafabe90c517cedd5e7b0d6af165728d7247 passed signature/resource/metadata checks and was installed at the fixed test path. That revision's CI passed. The stopped Omarchy fixture cold-booted and logged into its desktop with Integration ready using the new empty folders device.
- The signed guest Mac-directory result is still unverified: automated guest input remained delayed/inconsistent. Requested a manual guest Files observation of ~/Mac and ~/rollback-proof.txt; no reply is recorded yet. Host CPU/memory inspection did not show memory pressure (65 percent reported free).
- Recovery menu and confirmation titles now include the point creation date and time so repeated Protected backup names can be distinguished. This source change compiled successfully in /private/tmp/riftvm-recovery-label-build.log; it is newer than installed build 11 and awaits native UI verification in a later candidate.

### 2026-09-07 — Bind public release to unified functional evidence

- The publisher previously accepted one Linux boot fixture without proof of the primary Omarchy/macOS workflows. It now requires a complete local unified acceptance record bound to the exact ZIP SHA-256, version and source commit before notarization or publication. Required records cover primary guests, ISO install, window/quit lifecycle, integration isolation, directory permissions, guest-file rollback, portability, CLI and display behavior.
- Evidence attachments must exist beneath the report directory, be nonempty and match their recorded hashes. This checks record integrity and completeness, not the truth of observations; actual tests and review remain mandatory. No passing acceptance report was manufactured and no release was published.
- Added the report contract and marked the inherited EZVM field checklist historical. Regression validation: eight tests, 33 assertions, zero failures; publisher shell syntax and git diff checks passed.
- Signed build 11 macOS saved-session recovery reached Setup Assistant, advanced through region/language and privacy pages, and is now at Create a Mac Account. Account creation and desktop acceptance remain pending user interaction.

### 2026-09-07 — Signed build 11 Mac-folder observation and rollback baseline

- Native guest Files showed Home/rollback-proof.txt, confirming the earlier copy reached the guest home directory. Opened Home/Mac; after a fullscreen transition, Files showed Folder is Empty without the former No such device error. This validates the empty VirtioFS mount in signed build 11, not the full grant/removal matrix.
- Stopped Omarchy through its toolbar and created protected recovery point D0814DDF-BF9A-49FC-99E1-A6DC1D9AC01C at 2026-09-07T19:43:12Z. Its manifest records an APFS clone of Disk.asif and supporting configuration/firmware identity. Started the guest again. File mutation and restoration have not yet been verified.
- Display acceptance failed observation: directory breadcrumbs updated while old directory icons remained visible; fullscreen transition eventually redrew the empty directory. Leaving fullscreen during the next login showed oversized/cropped guest content that persisted across observations. The origin (guest rendering, native view or capture path) is not yet isolated. Do not treat delayed automation as successful login or a passing display test.
- GitHub source checks for 3dcc7981ee8d69840dc9f414ea5e1137483977a1 completed successfully in run 34156454191, including the new acceptance validator tests, Agent race tests and Xcode 27 compile checks.

### 2026-09-07 — Build 12 CLI acceptance and library error isolation

- Built and installed signed 0.1.0 build 12 from bb625486d0010315948ea2eb0724d0684f75faf4. ZIP SHA-256: 25c17b0339126706fb6b97a29078759b670d350cf00be724e5c0b3c8d234ecb2. Unsandboxed strict code-signature verification, production entitlement allowlist and exact metadata verification passed. No notarization or public release is claimed.
- Normal App quit saved both original macOS and Omarchy sessions and all runtime processes exited. Full build 12 CLI acceptance against independent Debian disk-only clones passed, including explicit shutdown retries, concurrent ownership, SIGKILL restart, saved-state preservation/recovery and EFI recovery. Log: /private/tmp/riftvm-candidate12/cli-acceptance.log. Temporary clones were removed and no runtime process remained after the verifier.
- Reopened macOS through the native workspace library. Omarchy remains saved. Automated path entry in the host NSOpenPanel also lost characters and clipboard paste timed out; this is evidence that input failures are not confined to the guest. Actual guest display behavior still needs independent visual confirmation.
- Selecting an invalid directory reproduced a separate product issue: an operation error overwrote the library-load error state, hiding all valid workspaces. Only loadConfig now changes the persistent load error; operation failures retain their alert without hiding the loaded library. Unsigned App build and diff checks passed. This fix is newer than installed build 12 and requires later GUI acceptance.

### 2026-09-07 — Build 14 fresh Omarchy and exact CLI acceptance

- Signed build 14 is 0.1.0 from clean source 4baf7b93f1000aca1c17d08ce9fb4927c77a65b3. ZIP SHA-256: 0984a4356203889fe129981f26b6e2fe2b39d747d0bd16bbe27c78f0708849c4. Strict signature and exact version/build/source metadata checks passed. This is not a notarization or public-release result.
- Created Omarchy Fresh in the user's normal VM directory through the App, downloaded and verified the public factory image, and provisioned its first owner through the authenticated Guest Agent API using a temporary signed backend helper. Credentials are excluded from this record. The helper's subsequent platform shutdown timed out; it exited, so that shutdown is not a pass.
- The App then cold-started the new guest and existing-password login visibly reached its desktop. Stop Omarchy returned it to Stopped. After quitting and reopening the App, a second cold start/login and a later idle-lock-screen unlock both reached the desktop. The original Omarchy-Rollback instance remains stopped and preserved.
- Ordinary guest menu operations and Command shortcuts still did not provide reliable immediate feedback. Fullscreen and ordinary-window observations are insufficient to distinguish input delivery from guest/native/capture redraw delay. The opt-in content-free input log yielded no timing events; absence of those events is not proof that the guest received no input. The diagnostic default was disabled after collection. Input/display acceptance remains open.
- Full signed build 14 CLI verification against independent installed-disk-only Debian clones exited 0. JSON interfaces, concurrent independent VMs, duplicate-start rejection, SIGKILL restart, rejected-state byte preservation, explicit cold recovery and EFI recovery passed. Several early guest shutdowns required the verifier's explicit normal retry. Evidence: /private/tmp/riftvm-candidate14/cli-acceptance.log. Both temporary clones were removed; only the GUI App and its fresh Omarchy runtime remained.
- Remaining unified requirements are not implied by these narrow results: mixed-guest input/clipboard/notification isolation, full folder grant/removal coverage, modified guest-file rollback, workspace portability, coordinated mixed-guest quit/restore, exact-candidate macOS desktop and Linux GUI acceptance, and reliable resize/fullscreen behavior still need their required observations. Distribution/notarization/Gatekeeper/cask/site download checks and a complete artifact-bound acceptance report remain outstanding.

### 2026-09-07 — Build 14 macOS desktop and mixed-state quit/restore

- The installed MacOS-Speakers fixture cold-started under build 14 to a completed macOS desktop. Clicking Finder in the guest Dock opened its Recents window. This independently confirms the user's completed Setup Assistant report; the IPSW installation itself occurred on an earlier candidate and was not repeated here.
- Closing the macOS VM window left the library status Running. Reopening preserved the Finder window and the same App PID 88259 and Virtualization service PID 89154. This verifies that specific close/reopen path, not all Dock/menu-bar/duplicate-open routes.
- Paused macOS through the toolbar, closed its window, and started/logged into Omarchy Fresh. Normal App Quit saved both guests and all App/VM processes exited. The macOS saved state was 1,509,953,536 bytes; Omarchy's was 771,756,032 bytes, each with its compatibility manifest.
- Reopened the installed App and both workspaces. macOS consumed its saved state and returned to the same Finder window. Omarchy consumed its saved state and returned directly to its desktop with authenticated Integration ready. This validates the successful mixed paused/running save-and-restore path; it does not validate failure handling or input/display isolation.
- Finished by normally quitting the two restored running guests. Both saved states were recreated and no App/VM process remained. No guest disk or downloaded installer was deleted. Display/input acceptance, data rollback, permissions/isolation, portability and distribution requirements remain open.

### 2026-09-07 — Include installation media in portable exports

- Actual build 14 GUI export of the stopped Debian fixture produced a checksummed package whose config still referenced /private/tmp/riftvm-debian-13.6.0-arm64.iso outside the payload. The manifest had 12 entries but did not include that installation image. A file-complete manifest was therefore insufficient proof of a portable boot configuration.
- Export now copies external USB installation media into a unique payload directory and rewrites only the exported config to relative paths. Capacity estimates include external media allocation. App USB storage loading accepts workspace-relative media while retaining read-only attachment behavior and compatibility with existing absolute ISO paths.
- Export/import validation rejects absolute, escaping or missing active storage references. External writable disks must be moved into the workspace before export; they are not silently copied without their dependency chains. Source configuration and installer files are preserved.
- All 20 portability tests passed, including export/import after deleting the original ISO, source-config preservation, and rejection/cleanup for missing or escaping disk paths. An initial sparse-only estimate regression was corrected before the passing run. Unsigned App build passed. This source change is newer than installed build 14 and needs signed runtime export/import/boot acceptance; no full portability or release pass is claimed.

### 2026-09-07 — Signed build 15 portable-media runtime check

- Built and installed signed 0.1.0 build 15 from clean source 2014e2fb2d5427ad7a2735f46e6eb430964e704f. ZIP SHA-256: 7f30fc69a98295a806c9bddf7dbd788f40f4025c7f253cd53073bc77a8ee0022. Strict installed signature, metadata, entitlement and packaged-resource checks passed. Source CI run 34163330084 completed successfully.
- GUI export of the stopped Build4-GUI-Debian fixture now includes its ISO under a unique InstallationMedia directory and uses relative active storage paths. Independently recomputed all 13 manifest hashes successfully; both referenced storage files exist within the payload. The original fixture and downloaded ISO remain unchanged.
- The native import file chooser still did not reliably select the export using the available UI control path. Cancelled it; no GUI import success is claimed. A temporary backend driver using the same revision's VMPortabilityManager imported the real export into /private/tmp/riftvm-candidate15/Imported-Debian.riftvm. Both hardware and workspace identity differ from the source.
- Only that disposable imported copy's audio configuration was changed from input/output to speaker-only, matching the established runtime test scope. Build 15 signed CLI validate and start succeeded. Virtualization process 91615 had a read-only descriptor for the imported package's 735,358,976-byte ISO, demonstrating use of the relative bundled media rather than the original host path. Normal stop returned stopped without retry. Logs are imported-start.json and imported-stop.json beneath the build 15 directory.
- This verifies the portable-media source fix and signed configuration/start/stop path, not guest login, GUI import completion, all storage-chain portability, the full build 15 CLI suite, or the remaining unified release requirements. No notarization/public release was performed.

### 2026-09-07 — Declare the native export package type

- Build 15's import picker visibly classified .riftvmexport as Folder. Info.plist exported only the workspace type, while the importer allowed arbitrary files and directories. This left export-package selection ambiguous and permitted invalid directory choices before the suffix guard.
- Declared com.riftvm.export conforming to com.apple.package with the riftvmexport extension. The import picker now accepts that type, treats packages as indivisible files and excludes ordinary directories. No Finder double-click importer or unsupported open handler is claimed.
- Plist validation, diff checks and the unsigned App build passed. The installed signed build 15 does not include this change; package recognition and GUI import need verification in the next candidate. This does not establish a fix for the independently reported guest input delay.

### 2026-09-07 — Build 16 GUI import and boot verification

- Installed signed build 16 from clean b346417fdcd6d82d6b6383b6e26da1701b1056a1. ZIP SHA-256: 420b6d11326499ec5b92e548e89559826b6f4d7247558ae9d3e8cacd2ef3f4ec. Strict signature, build metadata, packaged-resource/entitlement checks and source CI passed.
- The native picker identifies the retained export as RiftVM Export rather than Folder, without a disclosure triangle. Open is disabled without a valid selection. Its exposed Open Finder item action advanced to the destination save panel, avoiding the ineffective generic row clicks observed earlier.
- Imported through the GUI as a new workspace; the library grew from six to seven entries. Verified independent machine/workspace identities, rewritten name and active storage resolving within the new bundle. Only the disposable imported copy was changed to speaker-only before runtime testing.
- GUI start reached the installed Debian 13 tty login. Username and Return produced the password prompt. The virtualization runtime held the bundled ISO read-only. GUI Shut Down returned the workspace to Stopped and closed its window. No completed login, physical-host move or full portability matrix is claimed.
- Removed the stopped temporary GUI import from the library. After confirming no virtualization runtime remained, deleted the two disposable backend/GUI import copies. Retained the reusable export, original guests and installers. Omarchy input/display, integration isolation, guest-file rollback and remaining release gates stay open.

### 2026-09-07 — Wait for headless process exit before reporting stop success

- Full signed build 16 CLI verification failed on the pre-crash restart with process_ownership_unverified after earlier stop commands returned success. The cleanup guard retained the disposable fixtures. Subsequent inspection found the remaining record in stopped phase and its process absent; the full candidate run is failed, not passed.
- Stop previously returned immediately when the runtime published stopped, before the host process necessarily exited. Immediate restart could therefore encounter an exiting process whose executable path was unavailable. Stop now waits until the PID is absent (ESRCH); a stopped record alone is insufficient. It retains the existing timeout and unverified-process protection and adds no force stop.
- Added a real subprocess regression that publishes a stopped record but delays exit after SIGTERM. All 15 CLI tests passed, including unverified-live-process preservation. The test uses an explicit bash executable to avoid macOS sh launcher delegation changing process identity.
- The original guarded cleanup removed the retained failed-run fixtures only after stopped status could be verified. Obsolete build 10–14 derived caches were also removed after checking they had no open files and their ZIPs remained available (approximately 1.5 GB). Original guests and installers are preserved.
- This local source fix is newer than installed build 16 and requires another signed full CLI run. Remote push remains paused following automatic approval rejection; no publication is implied.

### 2026-09-07 — Signed build 17 CLI verification and replacement Omarchy

- Signed build 17 from 6fb666916e9bc25c7a21a1ac9b11741b8f33fe9a passed the full CLI verifier with exit 0, including concurrent guests, SIGKILL restart, saved-state preservation/recovery and EFI recovery. Four graceful shutdown retries were logged; no force stop was used. The disposable smoke directory was removed. ZIP SHA-256: ebbb75c999645ab146616c44146ba75472534736b0d7fa9addca7ad958fa6585. Installed GUI remains build 16; this does not establish GUI or distribution acceptance for build 17.
- Created Omarchy New through the native creation workflow with an independent 4 CPU, 8 GB, 64 GB workspace. Factory preparation and owner setup completed, and the desktop appeared with authenticated integration ready. Credentials are excluded from this record. Preserved existing instances.
- Replacement does not resolve the reported responsiveness problem: Command+Return had no observed terminal result, a desktop menu appeared only in a later observation, and ordinary menu text did not immediately appear. These observations do not distinguish event-delivery latency from display latency. The permission banner remains visible. Input/display acceptance is still open.

- Follow-up on Omarchy New: exited fullscreen, exported the native diagnostics locally, completed normal GUI shutdown and a cold start. Entering the existing short credential followed by Return reached the visible desktop in windowed mode. This proves one successful cold login, not sustained input responsiveness. The diagnostic export reports authenticated integration ready but contains no input timing or compositor frame evidence. SSH to the advertised address timed out. The optional host input log produced no timing events, so it is inconclusive; its collector and preference were disabled again. No permission or password changes were made during this follow-up.

### 2026-09-07 — Two Omarchy runtime lifecycle isolation

- Installed build 16 ran Omarchy New (PID 95035) and Omarchy Fresh (PID 95203) concurrently. Both reached visible desktops with integration ready; Fresh resumed its retained session. lsof associated each runtime with its own workspace Disk.asif. Workspace IDs and MachineIdentifier SHA-256 values were distinct.
- Closing New's window kept its library status Running. After pausing Fresh, the library showed Fresh Paused and New Running. Reopening New showed its existing desktop. Normal shutdown of New removed only PID 95035; Fresh remained Paused with PID 95203. Resuming Fresh restored integration ready, then its normal shutdown removed the last virtualization runtime. App PID 92662 remained resident.
- This verifies the observed independent lifecycle and disk ownership on build 16. It does not close cross-guest keyboard/clipboard/notification isolation, guest-file rollback, or exact final-candidate acceptance. No guest disks were deleted.

### 2026-09-07 — Make duplicate workspaces independent of external installation media

- The export path embedded absolute USB installation-media references, but direct workspace duplication still retained them. Deleting or moving the original ISO could therefore leave the duplicate dependent on the source environment despite its independent identity.
- Direct clone now embeds external installation media and validates active storage references inside its transactional staging directory, after resetting snapshot history. Source configuration remains unchanged; failures retain the existing rollback behavior.
- Added a regression that duplicates a workspace with an external ISO, removes the original ISO and verifies the clone contains the correct media bytes at a relative path. All 21 portability tests and the native unsigned App build passed. Installed build 16 does not include this fix. Snapshot-history export dependencies and signed GUI duplication still need their own evidence; no full portability acceptance is claimed.

### 2026-09-07 — Signed build 18 verification and local installation

- Built signed 0.1.0 build 18 from clean 05413ef26ad30a6d0c92f1c05287bcaeeafa6a97. Archive SHA-256: d81046233b0bed53838b7f2d64e81fe613662a1a597d48b642aa0de03414c401. Resource, metadata, entitlement and nested signature checks passed. Full signed CLI verification exited 0 with four graceful shutdown retries; disposable fixtures and all VM runtimes were removed.
- With all guests stopped, terminated the old resident test App normally and replaced the user Applications installation with build 18, retaining the old App under the candidate directory. Installed version and strict signature verification passed. GUI observation timed out; PID 96783 was alive, and a two-second sample showed the main thread in the AppKit event run loop rather than dyld startup. This is not proof of visible GUI readiness. No repeated launch or forced guest shutdown was performed.
- The candidate remains unpublished and unnotarized. GUI duplication, snapshot-history storage dependencies, input responsiveness and remaining unified acceptance gates are open.

### 2026-09-07 — Restore duplicate action in unified library

- Reconnecting the UI session by bundle identifier exposed the installed build 18 library successfully; prior observation timeouts did not prove an App startup hang. The library menu then revealed an actual migration omission: generic/macOS duplication existed only in the inherited detail view, not the unified workspace cards.
- Added Duplicate Workspace to the unified generic/macOS menu, reusing the existing independent-copy backend. The operation acquires a maintenance lease, releases it on cancellation/completion, runs copying off the main thread, displays progress and registers the resulting workspace. Busy/running workspaces cannot start it.
- Native unsigned App compilation and diff checks passed. The previously validated core copy tests cover independent media and identities; the new menu still requires signed GUI execution. Omarchy duplication needs its profile-specific implementation and is not claimed by this change.
