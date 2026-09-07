# RiftVM

Another world, right on your Mac.

RiftVM is a native workspace app for Apple Silicon and macOS 27. Omarchy and macOS are its primary guest systems; custom ARM64 Linux installations use a local ISO or a system-image download.

**0.1.0 is under development.** The new application is being built from the reusable EZVM implementation. A downloadable release will be linked here after signed-image, real-guest, and distribution acceptance is complete.

## Workspaces

- Create independent Omarchy or macOS workspaces in one app.
- Close a window while its virtual machine keeps running; reopen it from the menu bar.
- Select a default workspace or choose from your library.
- Keep workspace disks, identity, integration preferences, and notifications separate.
- Quit by saving supported machine state or shutting down the guest. Force stop requires an explicit choice.

The application and documentation are English-only. RiftVM uses a new `.riftvm` workspace identity and does not migrate EZVM data. Existing EZVM installations and disks are left untouched.

## Development

Open `RiftVM/RiftVM.xcodeproj` in Xcode 27 and select the `RiftVM` scheme. The shared scheme includes the App integration tests. The product bundle identifier is `com.riftvm.app`.

```sh
swift test
(cd GuestAgent/linux && go test ./...)
swift test --package-path Experiments/VZVirtioGPUPrototype
```

For local App tests without the distribution-only entitlements:

```sh
xcodebuild -project RiftVM/RiftVM.xcodeproj -scheme RiftVM \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  CODE_SIGN_ENTITLEMENTS="$PWD/scripts/virtualization-test.entitlements" test
```

`RIFTVM_DATA_ROOT` selects an isolated library and cache directory for acceptance work. Use disposable workspaces for all destructive tests. Passing unit tests or an unsigned build is not evidence that a release is ready.

See [the implementation plan](docs/RIFTVM_IMPLEMENTATION_PLAN.md) and [current verification record](docs/implementation/PROGRESS.md). Imported historical plans and workflows are reference material.

## Repositories

- [Application, CLI, and Guest Agent](https://github.com/riftvm/riftvm)
- [Omarchy image](https://github.com/riftvm/riftvm-omarchy-aarch64-image)
- [Website](https://github.com/riftvm/riftvm.github.io)

## License

See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md). Reused source retains its original attribution.
