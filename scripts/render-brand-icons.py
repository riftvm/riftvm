#!/usr/bin/env python3
"""Render the version-controlled RiftVM vector into the macOS icon catalog."""
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
renderer = shutil.which('rsvg-convert')
if not renderer:
    raise SystemExit('rsvg-convert is required to render the vector icon')
catalog = root / 'RiftVM/RiftVM/Assets.xcassets/AppIcon.appiconset'
for item in json.loads((catalog / 'Contents.json').read_text())['images']:
    size = int(item['size'].split('x')[0]) * int(item['scale'][:-1])
    subprocess.run([renderer, '-w', str(size), '-h', str(size), '-o', str(catalog / item['filename']), str(root / 'Resources/Brand/AppIcon.svg')], check=True)
print('Rendered all macOS App icon sizes from the RiftVM vector')
