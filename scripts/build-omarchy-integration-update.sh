#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
version=${1:?usage: build-omarchy-integration-update.sh version image-source-directory output-directory}
image_source=${2:?image source directory required}
output=${3:?output directory required}
[[ $version =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]]
[[ -z $(git -C "$root" status --porcelain --untracked-files=no) ]] || { echo 'Host source must be committed' >&2; exit 1; }
[[ -z $(git -C "$image_source" status --porcelain --untracked-files=no) ]] || { echo 'Image source must be committed' >&2; exit 1; }
source_revision=$(git -C "$root" rev-parse HEAD)
image_revision=$(git -C "$image_source" rev-parse HEAD)
# Use the same immutable Agent source as the factory rather than an incidental checkout.
agent_revision=$(sed -n 's/^RIFTVM_GUEST_AGENT_REF=//p' "$image_source/sources.env")
[[ $agent_revision =~ ^[0-9a-f]{40}$ ]]
mkdir -p "$output"
output=$(cd "$output" && pwd)
stage=$(mktemp -d /tmp/riftvm-integration-package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/source" "$stage/bundle"
git -C "$root" archive "$agent_revision" GuestAgent/linux | tar -xf - -C "$stage/source"
(cd "$stage/source/GuestAgent/linux" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags "-s -w -X main.version=$agent_revision" -o "$stage/bundle/rift-agent" .)
cp "$image_source/profiles/aarch64-virt/overlay/usr/local/libexec/omarchy-riftvm-display-watch" "$stage/bundle/"
cp "$root/GuestAgent/integration/update-integration.py" "$stage/bundle/"
python3 - "$stage/bundle" "$version" "$source_revision" "$image_revision" "$agent_revision" <<'PY'
import hashlib,json,pathlib,sys
folder=pathlib.Path(sys.argv[1])
manifest={'schemaVersion':1,'product':'riftvm-omarchy-integration','version':sys.argv[2],
          'installerSource':sys.argv[3],'imageSource':sys.argv[4],'agentSource':sys.argv[5],
          'files':{name:hashlib.sha256((folder/name).read_bytes()).hexdigest() for name in ('rift-agent','omarchy-riftvm-display-watch')}}
(folder/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
archive="RiftVM-Omarchy-Integration-$version.tar.gz"
COPYFILE_DISABLE=1 tar --format ustar -czf "$output/$archive" -C "$stage/bundle" manifest.json rift-agent omarchy-riftvm-display-watch update-integration.py
(cd "$output" && shasum -a 256 "$archive" > "$archive.sha256")
echo "Created $output/$archive"
