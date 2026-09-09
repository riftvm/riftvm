#!/bin/bash
set -euo pipefail
app=${1:?usage: verify-production-test-isolation.sh /path/to/RiftVM.app}
python3 - "$app" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('RiftVMAcceptanceHarness'):
    sys.exit('Refusing acceptance harness in a production release')
executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
# Inspect the executable and Debug's companion dylib, if present. These strings
# belong to executable test implementations, not passive diagnostics.
markers = (b'.riftvm-lock-cycle-', b'Omarchy clipboard probe typing Guest script path', b'RiftVMQueueBurst')
for binary in [executable, *executable.parent.glob('*.debug.dylib')]:
    data = binary.read_bytes()
    if any(marker in data for marker in markers):
        sys.exit('Refusing executable acceptance probes in a production release: ' + binary.name)
print('Verified production build excludes executable acceptance probes.')
PY
