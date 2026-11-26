#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

base_ref() { head -n 1 manifests/base.txt; }

lab_image() { echo "localhost/ultus-corp/$1:local"; }

# Join the common manifest with the role manifest into the install list.
# A role manifest that does not exist yet contributes nothing, so the first
# image builds before the role is written.
manifest() {
  local role=$1 list
  mkdir -p build/out
  list=(manifests/packages-common.txt)
  if [ -f "manifests/packages-$role.txt" ]; then
    list+=("manifests/packages-$role.txt")
  fi
  sort -u "${list[@]}" > "build/out/packages-$role.txt"

  if [ -f "manifests/packages-$role.lock" ]; then
    cp "manifests/packages-$role.lock" "build/out/install-$role.txt"
  else
    cp "build/out/packages-$role.txt" "build/out/install-$role.txt"
  fi
}

build_role() {
  local role=$1
  manifest "$role"
  podman pull -q "$(base_ref)" || return 1
  podman build --build-arg BASE="$(base_ref)" -f "Containerfile.$role" \
    -t "$(lab_image "$role")" . || return 1
  podman run --rm "$(lab_image "$role")" bootc container lint
}
