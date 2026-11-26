#!/usr/bin/env bash
# Build a bootable qcow2 from a role image with image-builder.
set -euo pipefail
cd "$(dirname "$0")/.."

role=${1:?usage: lab/build-disk.sh <role> <out.qcow2>}
out=${2:?usage: lab/build-disk.sh <role> <out.qcow2>}

. build/common.sh
read -r -a podman <<< "${LAB_PODMAN:-podman}"
image=$(lab_image "$role")

# The image builds rootless. The builder may run elsewhere, so it is copied in
# below, and only on a cache miss: a cached disk needs no privileged step.
if ! podman image exists "$image"; then
  build_role "$role"
fi

id=$(podman image inspect --format '{{.Id}}' "$image" | cut -c1-12)
cache="build/vm/cache/$role-$id.qcow2"
if [ -f "$cache" ]; then
  cp -f "$cache" "$out"
  echo "disk for $role from $cache"
  exit 0
fi

if [ "$("${podman[@]}" info --format '{{.Host.Security.Rootless}}')" = true ]; then
  echo "build-disk.sh: bootc-image-builder needs rootful podman" >&2
  echo "set LAB_PODMAN, for example LAB_PODMAN='sudo podman'" >&2
  exit 1
fi

if ! "${podman[@]}" image exists "$image"; then
  echo "copying $image into the build podman storage" >&2
  mkdir -p build/vm
  podman save -o build/vm/image.tar "$image"
  "${podman[@]}" load -i build/vm/image.tar
  rm -f build/vm/image.tar
fi

pub=$(cat lab-secrets/id_ed25519.pub)
mkdir -p build/vm
cat > build/vm/blueprint.toml <<EOF
[[customizations.user]]
name = "ultus"
key = "$pub"
groups = ["wheel"]
EOF

rm -rf build/vm/qcow2
"${podman[@]}" run --rm --privileged --security-opt label=type:unconfined_t \
  -v "$PWD/build/vm/blueprint.toml:/config.toml:ro" \
  -v "$PWD/build/vm:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "$(cat manifests/builder.txt)" \
  build --type qcow2 --rootfs xfs --output /output \
  --config /config.toml "$image"

mkdir -p "$(dirname "$cache")"
cp -f build/vm/qcow2/disk.qcow2 "$cache"
cp -f "$cache" "$out"
echo "disk for $role at $out"
