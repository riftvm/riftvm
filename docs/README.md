# RiftVM documentation

For installation, requirements, and creating your first workspace, start with the
[project README](../README.md). RiftVM requires **macOS 27 or later and Apple silicon**.

## Using and distributing RiftVM

- [Troubleshooting](TROUBLESHOOTING.md): display, input, guest setup, and signing problems.
- [Homebrew distribution](HOMEBREW.md): installation and maintaining the release cask.
- [Preinstalled-image manifest](PREINSTALLED_IMAGE_MANIFEST.md): the raw ARM64 image import contract.

## Engineering references

- [Guest Agent protocol](GUEST_AGENT_PROTOCOL.md): authentication, messages, and guest integration.
- [Custom VirGL architecture](CUSTOM_VIRGL_ARCHITECTURE.md): graphics ownership, invariants, and failure modes.
- [VirGL performance](VIRGL_PERFORMANCE.md): measurement and graphics validation.

The website source is [index.html](index.html). Release automation and validation
commands live in [scripts](../scripts). Superseded plans and historical migration
records remain available in Git history rather than the current documentation tree.
