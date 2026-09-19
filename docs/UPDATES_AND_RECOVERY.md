# Updates and recovery

RiftVM, the factory image, and the running Omarchy system have separate update paths.

## Try the latest factory image

In the window toolbar, open **Updates → Check Signed Factory Channel** to compare
its original factory version with the signed channel. This comparison does not
measure updates you have installed inside Omarchy.

To try the channel image, open **Omarchy ▾ → Remove Omarchy…**. This moves the
existing machine, including its disk and its data, to the Trash and returns the
window to **Prepare Omarchy**. Prepare again to fetch the current signed manifest,
verify the image, and create the machine using the normal download progress and
retry flow. There is no side-by-side copy and no automatic migration: the old
machine is gone once it is removed, so back up anything you still need from
**Open Shared Folder** first. This is a fresh installation, not an in-place disk
replacement.

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
Agent and display watcher. To receive them on an existing Omarchy machine (the
click and horizontal-scroll fixes in the Agent, and the display watcher that
repaints a wallpaper missing on the first login), first create the protected
recovery point described above, then download the paired integration package
from the
[`.11` image release](https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/tag/v4.0.3-riftvm.11).
Use RiftVM 0.3.2 or later. Inside the Guest terminal:

```sh
mkdir -p ~/Downloads/riftvm-integration-11
cd ~/Downloads/riftvm-integration-11
base=https://github.com/riftvm/riftvm-omarchy-aarch64-image/releases/download/v4.0.3-riftvm.11
curl --fail --location --remote-name "$base/RiftVM-Omarchy-Integration-v4.0.3-riftvm.11.tar.gz" &&
curl --fail --location --remote-name "$base/RiftVM-Omarchy-Integration-v4.0.3-riftvm.11.tar.gz.sha256" &&
sha256sum -c RiftVM-Omarchy-Integration-v4.0.3-riftvm.11.tar.gz.sha256 &&
mkdir package &&
tar -xzf RiftVM-Omarchy-Integration-v4.0.3-riftvm.11.tar.gz -C package &&
sudo python3 package/update-integration.py install
```

The integration package does not carry the cursor-plane setting that machines created
from `.10` or later have. Without it, Hyprland paints its own pointer and RiftVM shows a
second or lagging cursor. Add it once in the same terminal:

```sh
sudo sh -c 'mkdir -p /etc/xdg/uwsm && echo "export AQ_NO_ATOMIC=1" > /etc/xdg/uwsm/env-hyprland && printf "[Wayland]\nCompositorCommand=env AQ_NO_ATOMIC=1 start-hyprland -- --config /usr/share/sddm/hyprland.lua\n" > /etc/sddm.conf.d/20-riftvm-cursor-plane.conf'
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
recovery flow below. A newly downloaded factory image requires removing Omarchy
first, so it does not repair or replace the existing guest disk in place.

## Recover after a failed update

Stop Omarchy, then choose the dated recovery point from the **Recovery** menu.
Confirm only after saving any newer work you need: restoring replaces changes
inside the guest since that point. Wait for **Recovery Complete**, then start it.
If the window shows an error page, use **Stop and Enable Recovery** first.
RiftVM enables disk recovery only after stopping the VM. Interrupted restores use
transactional recovery; an ambiguous filesystem state is preserved for diagnosis.

Recovery points live with the machine. They are not a substitute for an external
backup against disk failure or deletion of the machine.

## Update RiftVM itself

Use `brew upgrade --cask riftvm`, or choose **Updates → Download RiftVM Update** for
GitHub Releases. Updating the app does not reinstall your guest operating system.
