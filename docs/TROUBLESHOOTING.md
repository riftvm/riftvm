# RiftVM troubleshooting

_Graphics guidance reflects the Custom VirGL Omarchy implementation in this source tree._

This guide records failures found while bringing Omarchy from bootable to
usable on RiftVM. Start with the symptom, preserve the first useful log, and
avoid changing the host, guest image, display backend, and Agent at the same
time.

## First identify the active path

Before debugging, record the host macOS version, guest OS/image version, RiftVM
version, CPU/memory allocation, and whether the VM is using Custom VirGL or
Apple graphics.

| Host and guest | Expected graphics path |
| --- | --- |
| Omarchy created from the home screen | Custom Virtio GPU with VirGL/ANGLE Metal; no Apple Virtio fallback |
| General Linux VM with Custom VirGL enabled | Custom Virtio GPU with VirGL/ANGLE; Apple Virtio fallback on initialization failure |
| macOS guest | Apple native Mac graphics path |

The RiftVM deployment target is macOS 27. Omarchy requires Custom VirGL.
A missing or broken runtime must produce a startup error, never a silent
software-rendering fallback. General Linux configurations retain their
separate Apple Virtio fallback policy.

Use the Omarchy window's **Integration**, **Updates**, and **Recovery** menus for
its status and recovery controls. `riftvm doctor` reports host information;
`riftvm validate "/path/to/Machine.riftvm"` validates general VM bundles with a
top-level `config.json`, not dedicated Omarchy workspaces. Do not attach disks,
enrollment files, or logs containing credentials to a bug report.

## App runs but no Control Center appears

A PID, valid signature, successful notarization, and Gatekeeper acceptance do
not prove that a SwiftUI window is visible. The app can restore the persisted
state in which all windows were closed.

- Click the app again or use the normal reopen action; do not assume the first
  process launch created a window.
- During release testing, reject an already-running RiftVM, launch the exact
  quarantined candidate through Launch Services, send reopen/activate, and
  require a visible window of at least 800x600 with a responsive event loop.
- A process-only smoke test is insufficient and must not replace GUI readiness.

## Keyboard input is missing, delayed, or appears after mouse movement

This symptom previously combined several distinct problems: the VM view did
not own focus, Agent input was sent before authenticated desktop ownership, and
rendering did not wake promptly after input changed the guest surface.

- Click once inside the guest and retry ordinary text before changing settings.
- Confirm the guest Agent is authenticated and its desktop input capability is
  ready. A connected socket alone is not desktop readiness.
- Keep boot/setup input and compositor-owned desktop input as separate states.
  Do not route both paths simultaneously; duplicate ownership causes missing or
  repeated keys.
- Test sustained typing, Return, password fields, Shift-modified characters,
  and input immediately after login—not only a single key on the setup screen.
- If characters become visible only after pointer movement, investigate render
  wakeup/frame scheduling as well as keyboard delivery.

## Accessibility is enabled, but the banner remains

In System Settings, check the permission for the exact RiftVM app you are
running. A development or temporary test build may not share the installed
app's permission identity. Return to RiftVM after enabling access; if the state
does not refresh, stop the guest and relaunch that app. Do not repeatedly
change signing identities or grant unrelated apps permission.

## Command-to-Super shortcuts do nothing

macOS Command must be translated to the Linux Super key on the authenticated
desktop path. Host menu shortcuts and focus handling can consume the chord
before it reaches the guest.

- Test both `Command-K` and `Command-Space` after Hyprland is fully ready.
- Verify key-down and key-up ordering; a stuck modifier can make later input
  look unrelated and broken.
- Command capture applies only while RiftVM is frontmost and the guest view
  owns keyboard focus. When another Mac app is active, its paste and screenshot
  shortcuts should stay with the host.
- Do not infer shortcut support from ordinary typing.

## Pointer capture or scrolling feels wrong

Omarchy uses authenticated Agent input with capability-negotiated absolute
pointer support. Pointer release, absolute movement, and wheel deltas are
separate behaviors.

- Verify that the pointer can enter and leave the VM before tuning scroll.
- Preserve high-resolution trackpad deltas, but accumulate and clamp them into
  guest wheel steps. Sending every macOS delta as a Linux notch can jump
  hundreds of lines.
- Test a browser and a terminal/list view. One application can mask a scaling
  or compositor issue.

## Full screen is stretched, oversized, or surrounded by black bars

Resizing the host view is not the same as changing the guest mode. Dedicated
Omarchy uses native automatic display reconfiguration and a guest display
watcher. The separate Custom VirGL path publishes a generation-tagged mode and
retains the display event until the guest acknowledges display-info/EDID.

- Test window resize completion, enter full screen, exit full screen, and
  repeated transitions.
- Keep aspect ratio while a new guest mode is pending; never fill the host view
  by stretching the previous framebuffer.
- A large password box is often the old guest resolution scaled into a new host
  rectangle, not a login-screen layout bug.
- Confirm the compositor selected the announced mode rather than judging only
  the outer macOS window size.

## First-run owner setup does not complete

The current flow collects username, password, keyboard, hostname, and time zone
in the native **Set up your Omarchy owner** form. RiftVM submits them once over
the authenticated Guest Agent channel. Completion requires the guest
provisioning service and desktop session to become ready.

- Use the matched RiftVM and guest-image/Agent versions.
- Retry helpers on real compositor/device readiness instead of using a fixed
  sleep as proof of readiness.
- Validate the entire flow from keyboard and user name through time zone,
  password, login, and the real Hyprland desktop. Passing the splash screen is
  not acceptance.

## Login succeeds and then the screen turns black

First distinguish a running guest with a missing frame from a stopped or
failed VM. Check VM state and logs before force-stopping it.

- A corrupt or incompatible saved state must fall back to a cold EFI boot.
- Custom VirGL does not support Virtualization.framework machine-state
  save/restore: restored RAM cannot reconstruct renderer contexts/resources.
  Use stopped-VM file snapshots instead.
- Test cold boot, clean shutdown, SIGKILL recovery, corrupt saved-state
  fallback, and a second boot. A one-time successful login is not enough.

## Repeated Keychain prompts

Changing signatures, identities, bundle locations, or ad-hoc development
builds can invalidate Keychain access expectations. Repeatedly clicking Allow
does not make an unstable identity suitable for automation.

- Test the exact Developer ID signed candidate that will be released.
- Keep Agent enrollment files mode `0600` and use a disposable VM clone for
  automated authentication/file-transfer tests.
- Do not weaken authentication or store a test password in source to avoid a
  prompt.

## Image import, disk size, and macOS compatibility

The public preinstalled-image manifest describes a decoded bootable ARM64 raw
disk. Its logical size and decoded SHA-256 are part of the product contract.
The 64 GiB disk is sparse: logical capacity is not the same as download or
physical host usage.

- Never confuse a local build artifact with the public GitHub image source.
- Verify every downloaded part, the complete compressed stream, decoded image
  hash, and logical size before import.
- Install transactionally so interruption cannot leave a machine that appears
  valid but contains a partial disk.
- Omarchy image changes must retain Mesa VirGL and the authenticated Guest
  Agent input/display capabilities required by the Custom VirGL path.

## Guest has no internet access

Graphics success does not imply networking success. The normal production
path is Virtualization.framework NAT.

- Test IP assignment, DNS, TLS, and an actual package-manager request; ping
  alone is not sufficient.
- Record whether failure is name resolution, routing, certificate/time, or the
  upstream repository.
- Signed releases include USB Accessory Access and vmnet entitlements.
  Custom builds can differ: check Settings → Signed capabilities
  for the running app. An entitlement does not prove that a network is active.
- NAT remains the default. Select bridged or custom vmnet networking deliberately
  for the required topology; changing modes is not a general fix for DNS or
  guest package-manager failures. Advanced network configuration belongs to the
  general VM configuration flow; the dedicated Omarchy flow uses NAT.

## Host capability is available, but the VM feature is not active

Settings reports host OS eligibility separately from signed entitlements.
Neither is an end-to-end validation of a particular VM. Check the guest OS,
hardware, VM configuration, and runtime status as well.

- Omarchy always constructs Custom VirGL at startup. General Linux VMs also
  expose a graphics preference; initialization failure in that separate flow
  can select Apple graphics instead.
- DiskImageKit layering requires a supported ASIF machine configuration. Do not
  infer the snapshot backend from a `.asif` extension alone.
- EFI Secure Boot is an explicit per-VM setting, not a global enabled state.
- USB passthrough requires the signed entitlement, user authorization, and a VM
  USB controller. Its controls are in the general VM window; the dedicated
  Omarchy window does not currently expose the same accessory controls.
- macOS guest graphics and iCloud eligibility depend on the supported guest and
  hardware configuration. Host OS version alone does not verify either feature.

## An acceptance-test warning appears

An **Automated acceptance testing** banner identifies the separate local test
app. Test failures leave its temporary VM available and are not equivalent to
a VM startup failure. The distributed RiftVM app excludes these automatic
probes. Stop the test guest and use the installed release for normal work.
See [Stability acceptance](STABILITY_TESTING.md) for test isolation.

## Omarchy still offers Update System

A factory image records packages at its build time. New upstream updates can
appear afterward; an update notification alone does not mean the image download
failed. Use [Updates and recovery](UPDATES_AND_RECOVERY.md) to create a protected
point before updating. A fresh factory workspace and an in-place guest update
are separate operations.

## Definition of fixed

A fix is complete only when the exact signed candidate—and then the
Homebrew-installed app—passes the affected scenario. For the Omarchy path this
includes clean import, complete first-run setup, login, continuous typing,
Command-to-Super, pointer and wheel, dynamic window/full-screen resolution,
NAT/DNS/TLS/package access, clean stop, recovery boot, and a second launch.

For implementation details and repeatable measurements, see
[Custom VirGL architecture](CUSTOM_VIRGL_ARCHITECTURE.md),
[VirGL performance validation](VIRGL_PERFORMANCE.md),
[Guest Agent protocol](GUEST_AGENT_PROTOCOL.md), and
[Homebrew distribution](HOMEBREW.md).
