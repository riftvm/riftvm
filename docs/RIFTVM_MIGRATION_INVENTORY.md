# RiftVM 1.0.0 migration inventory

Status: active implementation baseline  
Baseline commit: `94624b91728b13de34e939b3ca0082c709f7e33e`  
Baseline tag: `ezvm-last`

This inventory is the Phase A handoff for the unified
[RiftVM 1.0.0 implementation plan](RIFTVM_UNIFIED_PRODUCT_PLAN.md). It records
which implementation remains authoritative while the repository moves from the
two EZVM applications to one RiftVM application. A row may be removed only
after its replacement passes the stated evidence gate.

## Product entry points

| Current entry | Current role | RiftVM destination | Removal gate |
| --- | --- | --- | --- |
| `EZVM/EZVM.xcodeproj` | General VM application and multi-machine control center | `RiftVM/RiftVM.xcodeproj` | RiftVM builds the general, macOS, custom-Linux, and Omarchy journeys |
| `EZVM/EZVM/Application/Main/MainApp.swift` | General application `@main`, windows, settings, headless launch | RiftVM application shell | One application owns workspace routing and coordinated termination |
| Removed standalone Omarchy project | Former dedicated Omarchy application | No desktop application target | Omarchy GUI and acceptance coverage now run through RiftVM |
| `RiftVM/RiftVM/Omarchy` | Omarchy first-run, runtime, and integration UI | Omarchy workspace profile and views inside RiftVM | No second `@main` or process-global Omarchy workspace remains |
| `CLI/Executable/main.swift` | `ezvm` executable | `riftvm` executable | CLI reports RiftVM identity and operates only on `.riftvm` workspaces |

## Runtime and state ownership

| Concern | Authoritative implementation | Required migration |
| --- | --- | --- |
| General VM model and runtime | `EZVM/EZVM/Core/VMKit` | Rename to RiftVMCore while retaining one GUI/CLI validation engine |
| Cross-process ownership | `VMRunningRegistry` and VM runner leases | Key ownership by RiftVM workspace UUID and keep duplicate-open activation semantics |
| Omarchy disk installation | `VMOmarchyFactoryInstaller`, `VMOmarchyWorkspaceManager` | Replace the process-wide user-domain workspace with a layout rooted in an individual workspace bundle |
| Omarchy VM construction | `VMOmarchyVirtualMachineBuilder` | Consume a workspace/profile supplied by the unified coordinator |
| Guest integration | `VMOmarchyGuestAgentClient` and `EZVMOmarchy/Sources` controllers | Scope every session, clipboard route, notification, and diagnostic record to one workspace UUID |
| Window routing | `MainApp` URL-valued `WindowGroup` scenes | Route by stable workspace ID; resolve the current bundle URL through the registry |
| Preferences | Current global `UserDefaults` keys and VM-local configuration | Separate app preference, workspace preference, and active window state |
| Termination | `AppDelegate` plus `OmarchyApplicationTermination` | One coordinator stops or preserves every owned runner before app termination |

## Resource and release pipelines

The following remain resource pipelines, not separate desktop products:

- `Tools/OmarchyFactoryTool`
- `Tools/OmarchyRollbackAcceptanceTool`
- `Tools/OmarchySoakAcceptanceTool`
- `RiftVM/GuestOverlay`
- the Omarchy Factory, Overlay, and Agent build scripts

They will keep independent schema and upstream image versions, but published
desktop artifacts must converge on:

- application: `RiftVM.app`
- bundle ID: `com.everettjf.riftvm`
- package: `RiftVM-1.0.0.zip`
- CLI and Homebrew cask: `riftvm`
- workspace extension: `.riftvm`
- application support: `~/Library/Application Support/RiftVM`
- guest services: `rift-agent` and `rift-session-agent`

## Migration invariants

1. Two Omarchy workspaces never share a writable disk, machine identity,
   enrollment secret, saved state, snapshot branch, or Agent session.
2. The read-only Factory download cache may be shared only after digest and
   manifest verification.
3. Host input is delivered only to the focused VM display. Focus loss,
   pause, disconnect, and window close release held modifiers.
4. One host clipboard coordinator selects the active workspace. Background
   guests cannot overwrite the host clipboard or relay data to another guest.
5. Notifications carry a workspace ID and activation focuses that workspace's
   window.
6. Shared-directory grants belong to one workspace. Removing a workspace never
   removes the granted host directory.
7. macOS guests do not depend on Rift Agent and expose only verified native
   capabilities.
8. Every mutation uses an absent destination or transactional staging path;
   cancellation removes only artifacts created by that attempt.
9. Old EZVM data is neither migrated nor deleted automatically.

## Stage evidence

### A — Baseline

- [x] Source baseline is pinned by commit and tag.
- [x] Both application entry points, shared runtime, CLI, resources, and release
  surface are inventoried above.
- [ ] Immutable Omarchy and macOS fixture manifests are created for RiftVM.

### B — Identity

- [x] `RiftVM/RiftVM.xcodeproj` is the only desktop project.
- [ ] App, core module, CLI kit, executable, identifiers, environment variables,
  workspace format, guest services, and release artifact use the RiftVM names.
- [ ] A repository identity verifier rejects newly introduced shipping EZVM
  identifiers while allowing explicitly archived design history.

### C — Application merge

- [ ] One app creates and runs Omarchy and macOS workspaces.
- [ ] Two Omarchy workspaces and one mixed Omarchy/macOS pair run concurrently.
- [x] The standalone Omarchy target is removed; its 54 integration tests run in
  `RiftVMIntegrationTests` and pass on the native macOS 27 host.

### D/E — Workflow and integration

- [ ] Empty, single, default, multiple, offline, and failed workspace routing is
  covered.
- [ ] Input, clipboard, notification, sharing, Agent, disk, identity, snapshot,
  and lifecycle isolation is covered for concurrent workspaces.
- [ ] Factory, Overlay, and Agent resources are rebuilt with RiftVM identity.

### F/G — Release and launch

- [ ] The exact notarized `RiftVM-1.0.0.zip` passes signature, Gatekeeper,
  Homebrew, clean-account launch, VM boot, and integration gates.
- [ ] `riftvm.com`, repository documentation, screenshots, application icon,
  downloads, and support links expose one RiftVM product.

## Baseline verification commands

Run these before behavior-changing migration work and again after each stage:

```sh
swift test --disable-sandbox
xcodebuild -project RiftVM/RiftVM.xcodeproj -scheme RiftVM -configuration Debug build
xcodebuild -project RiftVM/RiftVM.xcodeproj -scheme RiftVMIntegrationTests -configuration Debug test
```

Signed-artifact and real-VM evidence remains mandatory; a successful compile is
not evidence for those gates.
