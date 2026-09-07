# RiftVM factory trust

Key ID: `riftvm-omarchy-factory-2026`.

`omarchy-factory-2026.pub` is the raw 32-byte Ed25519 public key embedded in the App Info.plist. SHA-256: `f41cfe40efa3bfa824c9f913439608147680e120993be3163671b696739bbb54`.

The private key is stored only on the release owner's Mac, outside Git, with owner-only permissions. Do not commit it or pass its bytes as command-line arguments. The factory tool accepts its file path. Release validation must verify the exact manifest and ASIF with this public key before publication. A new key requires an explicit App trust update.
