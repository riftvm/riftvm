# Updates and recovery

RiftVM, the factory image, and the running Omarchy system have separate update paths.

## Try the latest factory image

In the workspace toolbar, open **Updates → Check Signed Factory Channel** to compare
its original factory version with the signed channel. This comparison does not
measure updates you have installed inside Omarchy.

Choose **Create Workspace from Latest Image…**. Give the new workspace a distinct
name. Creation fetches the current signed manifest, verifies the image, and uses
its normal download progress and retry flow. Your existing workspace is retained.
Set up the new owner, check that the desktop works, then transfer selected files
using each workspace's **Open Shared Folder**. Keep the old workspace until you
have verified your files and applications. This is a fresh installation, not an
in-place disk replacement or automatic migration.

## Update an existing Omarchy system

1. Save your work. Choose **Updates → Prepare for Omarchy Update…**.
2. RiftVM stops the guest and creates a protected **Before Omarchy update** recovery
   point. Wait for **Recovery Point Created**. If it fails, fix the reported issue
   and retry before updating.
3. Choose **Start Omarchy**, then use **Update** in the Omarchy menu inside the guest.
4. Check the desktop and your applications after the update. Retain the recovery
   point until you are satisfied with the result.

## Update RiftVM integration inside an existing Guest

Omarchy's normal package update does not replace RiftVM's separately installed
Agent and display watcher. To receive demand rendering on an existing workspace,
first create the protected recovery point described above, then download the
paired integration package from the [`.7` image release](https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/tag/v4.0.3-riftvm.8).
Use RiftVM 0.1.21 or later. Inside the Guest terminal:

```sh
mkdir -p ~/Downloads/riftvm-integration-6
cd ~/Downloads/riftvm-integration-6
base=https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/download/v4.0.3-riftvm.8
curl --fail --location --remote-name "$base/RiftVM-Omarchy-Integration-v4.0.3-riftvm.8.tar.gz" &&
curl --fail --location --remote-name "$base/RiftVM-Omarchy-Integration-v4.0.3-riftvm.8.tar.gz.sha256" &&
sha256sum -c RiftVM-Omarchy-Integration-v4.0.3-riftvm.8.tar.gz.sha256 &&
mkdir package &&
tar -xzf RiftVM-Omarchy-Integration-v4.0.3-riftvm.8.tar.gz -C package &&
sudo python3 package/update-integration.py install
```

Save your work and reboot Omarchy to activate both components. Check keyboard
input, resizing, clipboard and desktop updates, then run
`sudo python3 package/update-integration.py accept`. The update preserves pairing,
user files, systemd configuration and your Hyprland preferences. It does not force
VFR on if your own configuration disables it.

To undo the update, run `sudo python3 package/update-integration.py rollback` and
reboot. If the Guest is inaccessible, restore the protected recovery point from
RiftVM. An interrupted installation is recovered when you rerun install or rollback.
For transaction behavior and limitations, see the
[integration installer guide](../GuestAgent/integration/README.md).

## If a repository download fails

A connection timeout or a package database download error is not a completed
update. Keep the error output and check connectivity to the configured repository
before retrying the normal Omarchy update. Do not disable package signatures or
TLS verification to work around download failures.

Keep the protected recovery point throughout the retry and the first reboot.
If the desktop no longer starts or the update leaves applications broken, use the
recovery flow below. A newly downloaded factory image creates a separate
workspace; it does not repair or replace the existing guest disk in place.

## Recover after a failed update

Stop Omarchy, then choose the dated recovery point from the **Recovery** menu.
Confirm only after saving any newer work you need: restoring replaces changes
inside the guest since that point. Wait for **Recovery Complete**, then start it.
If the workspace shows an error page, use **Stop and Enable Recovery** first.
RiftVM enables disk recovery only after stopping the VM. Interrupted restores use
transactional recovery; an ambiguous filesystem state is preserved for diagnosis.

Recovery points live with the workspace. They are not a substitute for an external
backup against disk failure or deletion of the workspace.

## Update RiftVM itself

Use `brew upgrade --cask riftvm`, or choose **Updates → Download RiftVM Update** for
GitHub Releases. Updating the app does not reinstall your guest operating system.
