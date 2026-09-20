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
- [Stability acceptance](STABILITY_TESTING.md): isolated test harness, production exclusion, and evidence requirements.
- [P0 validation](P0_VALIDATION.md): observed results and remaining physical checks.
- [Guest Agent protocol](GUEST_AGENT_PROTOCOL.md): authentication, messages, and guest integration.
- [Custom VirGL architecture](CUSTOM_VIRGL_ARCHITECTURE.md): graphics ownership, invariants, and failure modes.
- [VirGL performance](VIRGL_PERFORMANCE.md): measurement and graphics validation.

The website source is [index.html](index.html). Release automation and validation
commands live in [scripts](../scripts). Superseded plans and historical migration
records remain available in Git history rather than the current documentation tree.
