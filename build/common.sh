#!/usr/bin/env bash
set -euo pipefail

base_ref() { head -n 1 manifests/base.txt; }

core_image() { echo "localhost/ultus-corp/core:local"; }

lab_image() { echo "localhost/ultus-corp/$1:local"; }

# The core reference is written by build_core as <tag>@sha256:<digest>, so a
# role build names the exact core it was qualified against. The file is a build
# artifact, not a checked-in pin: the digest changes with every core build.
core_ref() {
  [ -f manifests/core.txt ] || return 0
  head -n 1 manifests/core.txt
}

# Podman resolves `repo@sha256:<id>` against a registry unless that digest is
# already a repo digest, and a locally built image has none. The build argument
# is therefore the bare digest, which resolves in the local store.
core_digest() {
  local ref
  ref=$(core_ref)
  [ -n "$ref" ] || return 1
  printf '%s\n' "${ref##*@}"
}

# The core owns the common manifest. A role manifest carries only its additions,
# so the role image stays the thin layer on top.
manifest() {
  local role=$1 list=() out="build/out/packages-$1.txt"
  mkdir -p build/out
  if [ "$role" = core ]; then
    list+=(manifests/packages-common.txt)
  elif [ -f "manifests/packages-$role.txt" ]; then
    list+=("manifests/packages-$role.txt")
  fi
  if [ ${#list[@]} -eq 0 ]; then
    : > "$out"
  else
    sort -u "${list[@]}" > "$out"
  fi

  if [ -f "manifests/packages-$role.lock" ] && [ "${LAB_UNLOCKED:-0}" != 1 ]; then
    cp "manifests/packages-$role.lock" "build/out/install-$role.txt"
  else
    cp "$out" "build/out/install-$role.txt"
  fi
}

# The digest alone cannot prove the core is current: a changed base pin, common
# manifest or base module leaves the old image id in place. So the cache key is
# a hash of every input Containerfile.core consumes.
core_inputs() {
  {
    cat Containerfile.core manifests/base.txt build/out/packages-core.txt
    if [ -f manifests/packages-core.lock ]; then
      cat manifests/packages-core.lock
    fi
    find modules/base -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  } | sha256sum | cut -d' ' -f1
}

build_core() {
  local ref id inputs
  manifest core
  inputs=$(core_inputs)
  ref=$(core_ref)
  if [ -n "$ref" ] && podman image exists "$(core_image)" \
    && [ "sha256:$(podman image inspect --format '{{.Id}}' "$(core_image)")" = "${ref##*@}" ] \
    && [ "$(cat manifests/core.inputs 2>/dev/null)" = "$inputs" ]; then
    return 0
  fi
  podman pull -q "$(base_ref)" || return 1
  podman build --build-arg BASE="$(base_ref)" -f Containerfile.core \
    -t "$(core_image)" . || return 1
  podman run --rm "$(core_image)" bootc container lint || return 1
  id=$(podman image inspect --format '{{.Id}}' "$(core_image)")
  printf '%s@%s\n' "$(core_image)" "$id" > manifests/core.txt
  printf '%s\n' "$inputs" > manifests/core.inputs
}

build_role() {
  local role=$1
  build_core || return 1
  manifest "$role"
  podman build --build-arg CORE="$(core_digest)" -f "Containerfile.$role" \
    -t "$(lab_image "$role")" . || return 1
  podman run --rm "$(lab_image "$role")" bootc container lint
}
