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
- New Ed25519 factory trust, ASIF byte comparison, multipart signing and signature verification succeeded. Assets remain draft; public cold download and final App manifest pinning are pending.
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
4. Consolidate remaining legacy release scripts around the one App; pin the validated immutable factory.
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
