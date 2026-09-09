# Homebrew distribution

RiftVM requires **macOS 27 or later and an Apple silicon Mac**.

## Install and update

```sh
brew install --cask riftvm/tap/riftvm
```

For an existing installation:

```sh
brew update
brew upgrade --cask riftvm/tap/riftvm
```

Alternatively, download the signed and notarized app from
[GitHub Releases](https://github.com/riftvm/riftvm/releases/latest).
The cask also links the bundled `riftvm` command into Homebrew's executable prefix.

## Maintain the cask

The authoritative installation manifest is
[Casks/riftvm.rb in the tap repository](https://github.com/riftvm/homebrew-tap/blob/main/Casks/riftvm.rb).
Keep version numbers, asset URLs, and SHA-256 values there instead of duplicating
release-specific values in documentation.

For a release update:

1. Build, sign, notarize, and validate the release archive using the repository's release scripts.
2. Publish the validated archive to GitHub Releases.
3. Update the tap cask's version, download URL, and SHA-256 to match that archive.
4. Verify installation of the published cask and the bundled CLI on a supported Mac.

The cask requires `arch: :arm64` and `macos: :golden_gate` (macOS 27).
Keep these requirements aligned with the app's deployment target and public
installation instructions. Users with an older Homebrew should run `brew update`.

The tap is `riftvm/homebrew-tap`; its short Homebrew name is `riftvm/tap`.
Routine updates require write access to the tap, not repository administration.
