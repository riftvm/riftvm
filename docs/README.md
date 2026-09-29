# RiftVM documentation

For installation, requirements, and preparing Omarchy, start with the
[project README](../README.md). RiftVM prepares one Omarchy machine from a signed,
verified factory image and renders it through Custom VirGL on a macOS 27
`VZCustomVirtioDevice`. It requires **macOS 27 or later and Apple silicon**.

## Using and distributing RiftVM

- [Release notes](RELEASES.md): what each release contains, and how to write new notes.
- [Updates and recovery](UPDATES_AND_RECOVERY.md): latest images, protected pre-update backups, and rollback.
- [The RiftVM window](WINDOW.md): the one-window states, toolbar, and wireframes.
- [Troubleshooting](TROUBLESHOOTING.md): display, input, guest setup, and signing problems.
- [Chinese input in Omarchy](OMARCHY_INPUT.md): user-installed Pinyin or Xiaohe and Shift-toggle configuration.
- [Homebrew distribution](HOMEBREW.md): installation and maintaining the release cask.

## Engineering references

- [V1 release checklist](V1_RELEASE_CHECKLIST.md): the real-guest display, cursor, input, graphics and shared-folder pass every release needs.
- [0.4.0 developer-day record](validation/v0.4.0-developer-day-2026-09-19/README.md): what a developer can do inside Omarchy, and how it was tested.
- [0.5.0 cleanup record](validation/v0.5.0-cleanup-2026-09-19/README.md): the full pass after the legacy and general-VM removal.
- [Wallpaper after a theme change](validation/wallpaper-theme-switch-2026-09-20/README.md): why the wallpaper goes missing, and why it is not RiftVM's doing.
- [Omarchy feature sweep](validation/omarchy-feature-sweep-2026-09-20/README.md): what works inside the guest, and the two gaps that do not.
- [OpenGL capability](validation/opengl-capability-2026-09-20/README.md): the guest gets GLES 3.0 and desktop GL 2.1, and why there is no core profile.
- [Developer-day suite](../Tools/DeveloperDay/README.md): the scripts behind those records, and how to run them.
- [Stability acceptance](STABILITY_TESTING.md): isolated test harness, production exclusion, and evidence requirements.
- [P0 validation](P0_VALIDATION.md): observed results and remaining physical checks.
- [Guest Agent protocol](GUEST_AGENT_PROTOCOL.md): authentication, messages, and guest integration.
- [Custom VirGL architecture](CUSTOM_VIRGL_ARCHITECTURE.md): graphics ownership, invariants, and failure modes.
- [VirGL performance](VIRGL_PERFORMANCE.md): measurement and graphics validation.

The website at <https://riftvm.com> has its own repository,
[riftvm/riftvm.github.io](https://github.com/riftvm/riftvm.github.io); this
repository carries no copy of it. Superseded plans and historical migration
records remain available in Git history rather than the current documentation tree.

## Scripts

Release automation and validation commands live in [scripts](../scripts).
"CI" below means the [RiftVM workflow](../.github/workflows/riftvm.yml) runs the
script on every push and pull request; "manual" means nothing calls it and a
person runs it when needed.

### Releasing

Both entry points need `APPLE_ID`, `APPLE_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, a
Developer ID Application identity in the keychain, and a clean worktree at
`origin/main`. They are kept as two separate scripts on purpose.

| Script | Use |
| --- | --- |
| `release-patch.sh` | Manual. The routine release: takes no argument, works out the next patch version from the latest `riftvm-v*` tag, bumps the project, tests, tags, and hands over to `publish-release.sh`. It refuses to run when the tag already exists, so it cannot resume. |
| `release-version.sh <major.minor.patch>` | Manual. Releases an explicit version: a minor or major release, or resuming an interrupted release whose tag already exists and points at `HEAD`. |
| `publish-release.sh <version>` | Called by the two scripts above. Builds, signs, notarizes, staples, verifies, publishes the GitHub release and the Homebrew tap cask, then syncs the checked-in cask. Finished steps are skipped when it runs again. |
| `build-release.sh`, `build-guest-agent.sh` | Called by `publish-release.sh` to produce the signed app archive and the Guest Agent archive. |
| `release-notes.sh`, `update-cask.rb`, `sync-checked-in-cask.sh` | Called by the release scripts: release notes from [RELEASES.md](RELEASES.md), the tap cask, and the follow-up commit that keeps `Casks/riftvm.rb` at the published release. |
| `verify-release-app.sh`, `verify-release-metadata.sh`, `verify-production-entitlements.sh`, `verify-production-test-isolation.sh`, `verify-factory-trust.sh`, `verify-homebrew-release.sh` | Release gates called by `build-release.sh` and `publish-release.sh`. Each also runs on its own against a built app. |

### Run by CI

| Script | Use |
| --- | --- |
| `integrate-omarchy-sources.rb` | Adds new Swift files to the Xcode targets. Needs the `xcodeproj` gem from the [Gemfile](../Gemfile). The shared schemes are checked in, so building does not depend on it. |
| `test-virgl-context-sync.sh`, `test-virgl-capture-preflight.sh`, `test-virgl-performance-gate.sh` | Graphics bridge, capture preflight, and performance gate tests. |
| `test-omarchy-factory-tool.sh`, `test-copy-sparse-raw-to-asif.sh`, `test-omarchy-guest-overlay.sh`, `test-omarchy-guest-overlay-package.sh`, `test-omarchy-image-source-integration.sh` | Factory image and guest Overlay pipelines. |
| `verify-riftvm-identity.sh`, `test-third-party-pins.sh`, `test-release-metadata.sh`, `test-release-signing-preflight.sh`, `test-sync-checked-in-cask.sh`, `test-omarchy-release-evidence.sh`, `test-omarchy-*-observation.sh` | Release gates that need no signing identity. |
| `verify-omarchy-*.sh` | The verifiers those tests exercise. They also run by hand against real evidence files. |
| `lib/common.sh` | Helpers shared by the tests and verifiers above. The release scripts do not use it. |

`test-release-notes.sh` runs from the two release entry points instead of CI.

### Manual

| Script | Use |
| --- | --- |
| `build-omarchy-factory.sh`, `sign-omarchy-factory-parts.sh`, `publish-omarchy-factory-assets.sh`, `copy-sparse-raw-to-asif.sh` | Build, sign, and publish an Omarchy factory image from a raw disk. |
| `build-omarchy-guest-overlay.sh` | Packages the guest Overlay; see the [Overlay README](../RiftVM/GuestOverlay/README.md). |
| `install-omarchy.sh` | User-facing installer: installs the cask and prepares Omarchy. |
| `build-virgl-runtime.sh`, `build-virgl-runtime-from-source.sh`, `prepare-virgl-sources.sh`, `verify-virgl-runtime.sh`, `virgl-runtime-pins.sh` | The pinned Custom VirGL runtime; see [runtime dependencies](../Experiments/VZVirtioGPUPrototype/RUNTIME_DEPENDENCIES.md). `build-release.sh` calls the from-source build and the verifier. |
| `capture-virgl-performance.sh`, `verify-virgl-performance.sh`, `benchmark-renderer-queue.sh` | Graphics measurements; see [VirGL performance](VIRGL_PERFORMANCE.md). |
| `build-omarchy-acceptance-harness.sh`, `test-omarchy-soak-acceptance-tool.sh` | Local acceptance harness and its soak tool test; see [stability acceptance](STABILITY_TESTING.md). The soak test needs `/tmp` and is not run by CI. |
| `verify-large-asif-snapshot.sh`, `verify-real-low-space-snapshot.sh` | Slow snapshot checks: a 64 GiB sparse image, and a disposable nearly full APFS volume. |
