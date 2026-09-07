# Omarchy factory release flow

The Linux workflow builds a raw-image **draft**. It does not publish the App's
factory: ASIF conversion, signing and native runtime checks run on macOS.

1. Build the image candidate in `riftvm/riftvm-omarchy-aarch64-image`. Preserve
   its raw SHA-256, source and Agent revisions, package inventory and provenance.
   A reused package base must remain explicit in that provenance.
2. On macOS, reconstruct and verify the raw image. Run
   `scripts/build-omarchy-factory.sh` with the raw disk, image version, exact
   Omarchy/Agent revisions, private signing key and an empty output directory.
   Set `RIFTVM_OMARCHY_FACTORY_RELEASE_BASE_URL` to the immutable candidate's
   `https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/download/<tag>`
   URL. The script verifies the result with the public key pinned in this repo.
3. Upload the signed factory manifest, ASIF parts and factory checksums to the
   same draft. Compare every uploaded part's length and GitHub digest with the
   signed manifest. Verify the complete ASIF and its signature locally. Complete
   native Guest startup, owner provisioning and integration acceptance.
4. Publish a candidate as a prerelease without replacing `latest`. This exposes
   the versioned URLs needed for public cold-download acceptance. Image
   publication does not approve or publish the App.
5. Pin that exact manifest URL in `VMOmarchyProfile.production`. Build the
   factory tool and run it with an empty cache to exercise the App's downloader:

   ```sh
   swift build -c release --product omarchy-factory-tool
   .build/release/omarchy-factory-tool download /tmp/new-factory-cache Resources/FactoryTrust/omarchy-factory-2026.pub
   ```

   The command succeeds only after signature, part and complete-image validation.
   It can also revalidate an existing cache. Use a new path for a cold test.
6. Create and boot a new workspace from the downloaded factory, then repeat the
   required first-install flow with the final signed App. Record the exact App
   archive digest, source/build, factory digest and Agent revision. Internal
   tooling does not replace GUI or signed-candidate acceptance.

Keep the private signing key outside repositories and release assets. New
factory versions apply to newly created workspaces; existing disks retain their
contents and are updated through the guest OS.
