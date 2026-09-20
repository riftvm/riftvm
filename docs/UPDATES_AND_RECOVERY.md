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
