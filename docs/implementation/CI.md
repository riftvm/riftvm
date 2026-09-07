# Continuous integration

The main repository runs Linux Agent race tests and compiles the unified App, App tests, Core and CLI tests on each pull request and main push. The workflow does not publish releases or access signing credentials.

GitHub's `xcode-27` public-preview runner supplies the macOS 27 SDK but currently runs macOS 26. It can compile RiftVM, whose minimum runtime is macOS 27, but cannot execute the App or its macOS 27 tests. The compile job deliberately uses `build-for-testing`; a green result is not runtime acceptance. See [GitHub's runner announcement](https://github.blog/changelog/2026-07-16-xcode-27-runner-image-now-in-public-preview/) and [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

Native App/Core/CLI tests and real Guest acceptance run on the current Apple Silicon macOS 27 host. Shipping requires rerunning the required checks against the exact signed candidate and recording its source revision, build number, image digest and Agent revision in release evidence. Hosted compile checks do not replace that gate.

## Candidate numbering

Use `RIFTVM_BUILD_NUMBER` when rebuilding a candidate for the same marketing version, incrementing it from the previous candidate. `build-release.sh` stamps and verifies that number and uses the selected `RIFTVM_DERIVED_DATA` for signing archives as well as ordinary builds. The default initial build number is 1. Keep each candidate in a separate output directory; a notarized intermediate candidate does not waive functional acceptance for the final build.
