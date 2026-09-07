# Unified release acceptance

The public publisher requires `RIFTVM_RELEASE_ACCEPTANCE` to name a local JSON
report for the exact release ZIP. Build the candidate first, complete real
functional testing, then write the report from retained observations. Rebuilding
or changing ZIP bytes invalidates that report. Do not copy pass results from an
older candidate. `scripts/verify-unified-acceptance.rb` checks completeness and
hash binding; it cannot establish that a human observation is true or that its
coverage is sufficient. Review each attachment before recording a pass.

Schema version 1 has these top-level fields:

- `schemaVersion`: 1
- `version`, `sourceCommit`, `archiveSHA256`: exact candidate identity
- `tester`, `testedAt`, `hostModel`, `hostOS`, `toolchain`: actual test context
- `factoryManifestSHA256`, `agentRevision`: factory and Agent provenance
- `checks`: an object with the required keys below

Each check has `status` (`passed` only after verification), an `observation`
describing the actual outcome, and a nonempty `evidence` array. Each evidence
entry contains a `path` relative to the report directory and its `sha256`.
Retain nonempty sanitized logs or screenshots beneath that directory. Never
include credentials, enrollment tokens or guest disks. Missing, changed or
symlinked evidence is rejected. No prefilled passing report is supplied.

| Check | Required observation |
| --- | --- |
| omarchy_public_cold_install | Empty-cache public image acquisition, verification, creation, owner setup and usable desktop with integration |
| omarchy_two_instances | Two distinct Omarchy guests concurrently running, independent identities, disks and lifecycle |
| macos_install_desktop | Real IPSW installation and completed Setup Assistant to a usable desktop |
| linux_iso_install | ARM64 Ubuntu or Debian ISO installation followed by disk-only boot and login |
| workspace_window_lifecycle | Close/reopen keeps the same running guest, Dock/menu-bar routing, duplicate-open activates existing owner |
| coordinated_quit | Running and paused mixed-profile guests save or shut down as reviewed; restore works; failure does not silently force-stop |
| focused_input_clipboard_isolation | Two Omarchy guests and mixed macOS/Omarchy windows receive only intended input, clipboard and notifications; modifiers release |
| folder_permissions_and_removal | Empty Mac entry usable; explicit read-only/read-write grants work; removed grants lose access and preserve host files |
| guest_file_rollback | Mutate guest-disk data, restore recovery point, verify original data; other guest and host shared data unaffected |
| workspace_portability | Move, duplicate and import/export preserve active storage chains; duplicate gets independent identity |
| cli_lifecycle | Exact candidate passes full CLI verifier, including independent guests, ownership, stop retry and saved-state preservation |
| windowed_fullscreen_display | No toolbar overlap; resize/fullscreen transitions preserve guest geometry and aligned input |

These are functional gates, not replacements for signing, notarization,
Gatekeeper, clean cask installation or website download checks. Long soak,
sleep/wake certification and physical USB hardware validation remain deferred;
do not record them as passed. Custom VirGL remains experimental until its
separate promotion requirements are met. The inherited EZVM field checklist is
historical and is not the unified RiftVM release checklist.

Validate before invoking the publisher:

```sh
ruby scripts/verify-unified-acceptance.rb "$archive" "$report" 0.1.0 "$commit"
```

The publisher validates this record before notarization and before publishing
refs or assets. It also retains the existing live CLI/VM and distribution checks.
