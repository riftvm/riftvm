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
