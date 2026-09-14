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

The `.6` candidate uses a complete rebuild, not an Agent-only rebake. Local signed
factory and fresh-owner acceptance results will be recorded before promotion.
