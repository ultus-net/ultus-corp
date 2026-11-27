#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
role=${1:?usage: test-image.sh <role>}
. build/common.sh
. build/checks.sh

assert_ok "image builds and lints" build_role "$role"
assert_ok "core image exists" podman image exists "$(core_image)"
# The producer's output must satisfy the same contract its fixture does, or CI
# compares a prefixed id against a bare one and fails on the prefix.
assert_ok "core ref is digest pinned" check_core_ref manifests/core.txt
# A changed base pin or common manifest must rebuild the core, so the recorded
# input hash is compared rather than trusted.
assert_eq "core inputs recorded" "$(. build/common.sh; core_inputs)" \
  "$(cat manifests/core.inputs)"
assert_ok "base package installed" \
  podman run --rm "$(lab_image "$role")" rpm -q podman
assert_ok "greenboot installed" \
  podman run --rm "$(lab_image "$role")" rpm -q greenboot
assert_ok "base is CentOS Stream 10" \
  podman run --rm "$(lab_image "$role")" grep -q '^VERSION_ID="10"' /etc/os-release
assert_ok "renderer sees tomllib" \
  python3 -c 'import tomllib'

finish
