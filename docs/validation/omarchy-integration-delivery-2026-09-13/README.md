# Omarchy integration delivery — September 13, 2026

## Existing Guest update qualification

Only the disposable `Performance Test (Temporary)` workspace was used, with a
stopped-disk APFS clone retained before testing. The personal workspace was not
started. The signed local demand-rendering acceptance Host from the preceding
P0 run was used; this installer adds no new Host rendering behavior.

The test staged the `.5` factory Agent source (`c8a3b4308c2635e2a29a5ecd224c52799237b4ac`)
and pre-change watcher on the disposable Guest disk, then ran the packaged updater.
The paired candidate Agent source is the released 0.1.21 commit
`524cde8fa88118122910a0a2210c8b776d433a15`; the watcher comes from the `.6` image source.
Hashes identify the exact local binaries. Different build toolchains can yield
different binary hashes for the same immutable Agent source.

- Install completed and the actual factory enrollment mount's configuration was
  byte-identical before/after (only the pass marker, not enrollment contents or
  hashes, is retained in this report).
- After reboot/cold start, Agent and both session services were active. VFR was
  `true, set:false`; a keyboard-only command produced the observed final blue frame.
- Rollback restored both original file hashes, modes, and unchanged enrollment.
  After a further cold start, services and keyboard input worked; VFR was again
  `false, set:true`, demonstrating that the older override was active.
- Reinstallation after rollback succeeded. The temporary Guest was stopped.
- Eight offline installer tests cover checksum/architecture/symlink rejection,
  second-file write failure, interruption recovery, corrupt-backup refusal,
  idempotence, acceptance and rollback. These are fault-injection tests, not a
  claim of a physical power-cut test. Four factory profile tests passed.

The first script attempt assumed the generic `/etc/rift-agent/config.json` path
and stopped before changing components. It was corrected to the factory's
`/run/rift-agent-config/config.json`. The installer itself never touches either
configuration path. An initial harness launch without a persistent session was
restarted with the existing isolated runner pattern; it is not counted as a pass.
One login required an additional Return after the harness populated the credential.

Archive extraction initially emitted macOS extended-header warnings. The final
packager uses ustar to remove those headers; the tested installer logic and payload
sources are unchanged. Reboot activation, backup retention and interruption limits
are documented in the installer guide. New 3D, energy, physical hot-plug and Host
sleep qualification are separate TODOs.

## Fresh factory qualification

Full ARM64 build run: https://github.com/riftvm/riftvm-omarchy-aarch64-image/actions/runs/34792828682

The `.6` candidate uses a complete rebuild, not an Agent-only rebake. All downloaded
asset hashes and the complete 64 GiB raw digest matched. Raw-to-ASIF byte comparison,
trusted signing-key check, signed manifest verification and multipart checks passed.
The signed manifest and its checksums are retained in `factory6/`.

A fresh workspace was prepared from that verified factory, registered through the
existing Registry API, and started in the local acceptance Host. The acceptance-only
owner setup completed using the temporary credential. The observed desktop reported
`provisioningPending:false`, matching Agent version/hash, active system/session
services and `debug:vfr=true, set:false`. Five red/green update pairs completed and
the final blue frame was visibly observed without pointer-driven updates.

A subsequent cold start passed shared-folder/file import, text and PNG clipboard
round trips, dynamic resolution round trip, and all six size/focus cycles across the
two existing 60/120 Hz displays. The final keyboard command and VFR/service snapshots
passed after those cycles. This is display/focus recovery, not a 120 FPS claim.
The fresh temporary Guest was then stopped. The personal Guest was never started.

The final integration archive uses the exact tested installer and payload bytes;
only portable archive headers and recorded installer-source metadata changed.
`final-package.json` records this comparison and the archive digest. The update
Agent and full factory Agent were built from the same immutable source pin; their
individual build provenance and component hashes are retained.
