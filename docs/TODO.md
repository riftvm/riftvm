# TODO

## Omarchy demand rendering (P0)

Implemented in [Host/Agent PR #2](https://github.com/riftvm/riftvm/pull/2) and
[image watcher PR #1](https://github.com/riftvm/riftvm-omarchy-aarch64-image/pull/1).
See [the validation report](validation/omarchy-demand-rendering-2026-09-13/README.md)
for completed checks and raw evidence. The local test closes the key tested
scenarios, not broad compatibility qualification.

- [x] Build and publish a new signed Omarchy factory containing both the updated
  Rift Agent and display watcher; qualify fresh owner setup with the matching Host.
- [x] Provide and validate an explicit upgrade path for existing Guest Agent and
  watcher installations. A Host-only update does not deliver the full idle gain;
  preserve user compositor configuration and existing disks.
  Delivery: [signed factory .6 and paired updater](https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/tag/v4.0.3-riftvm.6),
  [upgrade instructions](UPDATES_AND_RECOVERY.md), and
  [fresh-owner / upgrade / rollback evidence](validation/omarchy-integration-delivery-2026-09-13/README.md).

- [ ] Exercise complex 3D applications and sustained changing workloads with VFR
  enabled; verify final-frame correctness and the existing latency gate.
- [ ] Qualify physical display hot-plug and real Host sleep/wake, including input
  and final-frame recovery.
- [ ] Repeat longer controlled idle A/B samples with visibility and lock-state
  monitoring; measure energy separately before making power-saving claims.
- [ ] Expand GPU/application compatibility coverage before declaring P0 fully closed.

## Further performance work

- [ ] P1: investigate refresh-rate-aware presentation and input-to-photon latency,
  including 120 Hz displays; display/focus tests do not establish 120 FPS support.
- [x] Reduce idle Guest display watcher compositor queries: ten-poll audits,
  immediate DRM-change reconciliation and fast retries. One-second DRM reads remain.
  See [watcher PR #3](https://github.com/riftvm/riftvm-omarchy-aarch64-image/pull/3)
  and [native validation](validation/watcher-idle-2026-09-13/README.md).
- [ ] Run a matched Try Omarchy comparison with equivalent hardware/resources,
  resolution, workloads, and separate CPU, frame latency, and energy measurements.
