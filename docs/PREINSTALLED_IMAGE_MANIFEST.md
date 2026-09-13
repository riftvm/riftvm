# RiftVM preinstalled-image manifest

The preinstalled-image manifest is the source of truth for importing a decoded,
bootable ARM64 raw disk into a general RiftVM bundle (`config.json`). This is
the CLI import contract, not the signed ASIF factory manifest used by the
dedicated Omarchy creation flow. Release-specific download metadata may add
fields of its own, but these fields are the stable RiftVM contract:

```json
{
  "schemaVersion": 1,
  "kind": "com.riftvm.preinstalled-image",
  "architecture": "arm64",
  "minimumRiftVMVersion": "1.0.0",
  "product": {
    "id": "org.example.linux",
    "name": "Example Linux",
    "version": "2026.08"
  },
  "disk": {
    "format": "raw",
    "virtualSize": 68719476736,
    "sha256": "64-lowercase-hex-digits"
  },
  "virtualMachine": {
    "name": "Example Linux",
    "remark": "Optional user-facing release description"
  }
}
```

`virtualSize` is the decoded disk's logical byte size, not its allocated or
compressed size. RiftVM accepts only `arm64` and `raw` in schema 1 and requires a
minimum 10 GiB disk. It verifies the logical size and streams SHA-256 before
creating any destination bundle.

Install a locally decoded image with the signed CLI:

```sh
riftvm install-image preinstalled-image.json \
  --image disk.raw \
  --destination "$HOME/RiftVM Virtual Machines/Example Linux.riftvm" \
  --timeout 300
```

The CLI and app validate the manifest independently. The app creates the
machine in a hidden sibling staging directory, generates fresh host machine
identity and EFI variable storage, and atomically renames the completed bundle
into place. Failure, timeout, SIGINT, or SIGTERM must leave the destination
absent. The decoded source image is never consumed.

Distribution manifests may include an `archive` object containing compression,
aggregate checksum, compressed size, and ordered parts. Downloaders must verify
each part and the complete archive before decoding; RiftVM still verifies the
decoded disk against the stable `disk` object.
