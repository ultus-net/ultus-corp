#!/usr/bin/env bash
# Build a bootable qcow2 from a role image with image-builder.
set -euo pipefail
cd "$(dirname "$0")/.."

role=${1:?usage: lab/build-disk.sh <role> <out.qcow2>}
out=${2:?usage: lab/build-disk.sh <role> <out.qcow2>}

. build/common.sh
pub=$(cat lab-secrets/id_ed25519.pub)
img=$(cat manifests/builder.txt)

mkdir -p build/vm
cat > build/vm/blueprint.toml <<EOF
[[customizations.user]]
name = "ultus"
key = "$pub"
groups = ["wheel"]
EOF

if ! podman image exists "$(lab_image "$role")"; then
  build_role "$role"
fi

podman run --rm --privileged --security-opt label=type:unconfined_t \
  -v "$PWD/build/vm/blueprint.toml:/config.toml:ro" \
  -v "$PWD/build/vm:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "$img" build --type qcow2 --rootfs xfs --output /output \
  --config /config.toml "$(lab_image "$role")"

cp -f build/vm/qcow2/disk.qcow2 "$out"
