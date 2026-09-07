# RiftVM 0.1.0 Implementation Plan

Status: implementation in progress. See implementation/PROGRESS.md for verified milestones and remaining release requirements.

## Confirmed product contract

- New application and repositories under the RiftVM organization. Reuse and modify copied EZVM implementations; do not modify the original repositories.
- Apple Silicon and macOS 27 only. English-only application and website.
- App: RiftVM. Bundle identifier: com.riftvm.app. Version: 0.1.0. Initial build: 1; increment for rebuilt candidates.
- One desktop application with Omarchy and macOS as primary workspace profiles and Custom ARM64 Linux as a secondary ISO flow.
- Entirely new native application UI, website design, icon, and visual identity. Legacy art is reference material, not the approved design.
- New .riftvm format, RiftVMCore/RiftVMCLIKit, riftvm CLI, RIFTVM_* environment variables, and Rift Agent services. No EZVM migration or compatibility promise. Never delete existing user data.
- Closing a workspace window keeps its VM running. A persistent menu bar item lists workspace status and provides open, create, and quit actions. Keep normal Dock behavior.
- Quit coordinates every running VM: save state when supported; otherwise prompt for graceful shutdown. On timeout offer wait, cancel quit, or explicit force stop. Never silently force stop.
- New factory releases apply to newly created workspaces only. Existing guests update through their own system tools; no automatic disk replacement.
- Retain the original unified plan's functional scope, multi-instance isolation, explicit directory permissions, and failure recovery requirements. This document overrides its identity, repository, version, localization, and visual decisions.
- Long soak and sleep/wake certification remain follow-up work; remove contradictory inherited release requirements without weakening required first-release functional checks. Do not claim those deferred checks passed.

## Repository ownership

| Repository | Responsibility |
| --- | --- |
| riftvm/riftvm | App, reusable runtime, CLI, Linux Agent/session Agent, host integration, tests, signed application release |
| riftvm/riftvm-omarchy-aarch64-image | Reproducible image/overlay assembly, signed manifest, multipart assets, provenance and image release |
| riftvm/riftvm.github.io | New English GitHub Pages website; initially default Pages URL, later riftvm.com |
| riftvm/.github | Organization profile and project navigation |
| riftvm/homebrew-tap | Approved new tap for the single riftvm cask; create during distribution setup |

The source of truth for Agent code is the main repository. Pin an exact main-repository revision in image builds. Pin the compatible immutable factory manifest and verification trust in an App candidate. Record App commit, Agent revision, image revision, image digest, and build number in acceptance evidence.

## Baseline and provenance

Imported tracked source from EZVM commit 94624b91728b13de34e939b3ca0082c709f7e33e, without its Git history, build outputs, dist files, or user VM data. Preserve licenses and third-party notices. Legacy workflows are parked in docs/implementation/legacy-workflows until reviewed; do not enable stale release or Pages workflows in the new App repository.

The imported projects, README, plans, and assets are a reference baseline, not a finished RiftVM implementation. Historical plans do not override this document.

## Implementation sequence and gates

1. Establish identity and build: rename projects/modules/CLI, set version and bundle identity, define a versioned workspace format, replace legacy product references, retain relevant tests. Gate: core and CLI tests plus unsigned App build.
2. Build new native shell: workspace registry/coordinator, UUID identity and cross-process ownership, default routing, windows, persistent menu bar, resource checks, and quit coordination. Gate: correct single/multiple/default workspace routing and reopen without duplicate runners.
3. Integrate macOS and Custom Linux: IPSW acquisition/local install, ISO install, runtime, storage, networking, graphics, snapshots, import/export. Gate: real clean installs and snapshot recovery on the current Mac.
4. Integrate Omarchy: new image contract and trust, shared read-only cache, per-workspace writable storage/identity, owner setup, cancellation and recovery. Gate: public-download cold installation and two independent Omarchy instances.
5. Scope integration: focused input, modifier release, active-workspace clipboard selection, notification routing, authorized read-only/read-write directory sharing. Gate: two Omarchy guests and mixed Omarchy/macOS workloads do not exchange data or events accidentally.
6. Consolidate distribution: one App workflow/release archive, Developer ID signing and notarization, updated image pipeline, new tap, exact-candidate acceptance evidence. Gate: signed archive round trip, Gatekeeper, CLI and cask installation, real guest checks. Version 0.1.0 does not waive these gates.
7. Build and launch the new site and organization profile: coherent new visual identity, one download destination, accurate capabilities and English documentation. Gate: default Pages HTTPS and download/install flow; custom-domain verification after the owner configures DNS.

Use small reviewable commits separating imported baseline, mechanical identity edits, and behavior changes. No public candidate until required gates pass. Keep application and image rollback independent of original EZVM data.

## Workspace invariants

A workspace UUID owns its runner, window routing, storage identity, integration credentials, settings, and notifications. Moving a workspace preserves identity; explicit duplication generates fresh identity and credentials. Opening the same workspace twice activates the existing owner. Copies with conflicting identities must be detected. A snapshot rollback must not affect other workspaces or host shared directories.

Persist the registry, per-workspace metadata, default selection, and window preferences separately with a single authoritative source for each. Use transactional creation and recovery markers. Cancel only the current operation's temporary products; never delete a shared cache used by another operation.

## Build environment and external dependencies

- Current Mac is the native VM acceptance host. Observed macOS 27.0 (26A5425a), Xcode 27.0 (27A5252f); capture exact versions again for release evidence.
- Existing image workflow runs on GitHub Actions ubuntu-24.04-arm, building an ARM64 Docker builder and pinned Agent/source inputs. Adapt the existing workflow; validate runner availability and organization Actions permissions before relying on it.
- Existing image workflow is restricted to everettjf/omarchy-aarch64-image and references old Agent checkout paths. Replace those explicitly before enabling new releases.
- User authorizes use of their Developer ID. Verify certificate/entitlement/notarization availability without printing or committing credentials. Create fresh image trust configuration deliberately; do not treat a renamed key ID as a new key.
- riftvm.com is owned but DNS is not configured. Default Pages hosting is sufficient for development; DNS/certificate readiness remains an external launch dependency.
- Homebrew tap addition is approved. Repository creation and cask setup are distribution work, not completed baseline work.

## Completion definition

A user downloads one signed RiftVM 0.1.0, creates and switches between Omarchy/macOS workspaces, can close and reopen their windows while VMs run, and can quit safely. App, CLI, Agent, image, cask, site, and organization identity agree. Required evidence belongs to the exact shipped candidate; unfinished optional work is clearly documented.
