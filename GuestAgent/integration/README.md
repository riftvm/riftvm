# Existing Omarchy integration updates

This package upgrades an existing RiftVM Omarchy Guest's Agent and display watcher
together. It does not enroll a new machine, overwrite `/etc/rift-agent/config.json`,
edit Hyprland settings, replace systemd units, or reinstall the operating system.
It requires the existing standard Agent and watcher paths and Linux AArch64.

Before installing, save your work and use **Updates → Prepare for Omarchy Update…**
in RiftVM. Wait for the protected recovery point, then restart the Guest.

Download the integration archive and its `.sha256` from the same versioned official
image release, verify it with `sha256sum -c`, and extract it into a new directory.
The checksum detects damaged downloads; obtain both files over HTTPS from the
trusted project release. Never use an unverified third-party installer as root.
Run inside the Guest:

```sh
sudo python3 update-integration.py install
sudo python3 update-integration.py status
```

Save your work and reboot Omarchy. Both new files become active at reboot; the
installer deliberately does not restart desktop services while you are working.
Check keyboard input without moving the pointer, resize, clipboard, and terminal
updates. `hyprctl -j getoption debug:vfr` should report the compositor/user's chosen
value. The installer does not force VFR on if your own configuration disables it.
After successful validation, run `sudo python3 update-integration.py accept`.

If there is a regression, run `sudo python3 update-integration.py rollback` from
the same package and reboot. Both original files and their modes are restored.
If the desktop cannot be reached, restore the protected recovery point from RiftVM.
The installer retains its backup until the next accepted update is replaced.
An unaccepted update cannot overwrite that backup with another version.

Writes are atomic per file and journaled as a two-file transaction. A write failure
restores both backups; if the process or machine stops mid-update, rerunning install
or rollback first recovers the interrupted transaction and asks for a reboot.
No live services are changed during the transaction. The Guest can temporarily
boot mixed versions after a power loss until recovery runs; the stopped-VM recovery
point remains the fallback if it cannot boot. Status reports disk transaction state,
not proof that the running services have restarted or the desktop is healthy.

## Build and test

`scripts/build-omarchy-integration-update.sh VERSION IMAGE_SOURCE OUTPUT` builds the
Agent from the image source's immutable pin and takes the watcher from that same
committed image checkout. The package manifest records both revisions and file hashes.

`python3 -m unittest discover -s GuestAgent/integration -p 'test_*.py'` exercises
configuration preservation, idempotence, rollback, interruption recovery, corrupt
payload/backup rejection, architecture checks and symlink refusal. `--fixture-root`
is solely for offline filesystem tests and never starts services.
