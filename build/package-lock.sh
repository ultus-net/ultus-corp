#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. build/common.sh
. build/checks.sh

[ "${1:-}" = "resolve" ] || { echo "usage: build/package-lock.sh resolve <core|role>"; exit 1; }
role=${2:?usage: build/package-lock.sh resolve <core|role>}

rpm_list() {
  podman run --rm "$1" rpm -qa --qf '%{NAME}-%{EVR}.%{ARCH}\n' \
    | grep -v '^gpg-pubkey-' | LC_ALL=C sort
}

# Resolve against the manifests, not the current lock, or a stale lock would
# keep producing itself.
export LAB_UNLOCKED=1

if [ "$role" = core ]; then
  build_core
  rpm_list "$(core_image)" > manifests/packages-core.lock
  echo "manifests/packages-core.lock"
  exit 0
fi

build_role "$role"
rpm_list "$(core_image)" > build/out/core-rpm.txt
rpm_list "$(lab_image "$role")" > build/out/role-rpm.txt
# The core owns everything below this line. The role lock carries only what the
# role adds, so a core change never rewrites every role lock.
lock_delta build/out/core-rpm.txt build/out/role-rpm.txt \
  > "manifests/packages-$role.lock"
# A delta lock is only useful if the core closure plus the delta is the role
# image. Anything else is a lock that cannot rebuild what was tested.
if ! lock_covers build/out/core-rpm.txt "manifests/packages-$role.lock" \
    build/out/role-rpm.txt; then
  echo "role lock does not describe $role: core closure plus lock differs from the image" >&2
  diff <( { cat build/out/core-rpm.txt "manifests/packages-$role.lock"; } \
    | LC_ALL=C sort -u ) <( LC_ALL=C sort -u build/out/role-rpm.txt ) >&2 || true
  exit 1
fi
echo "manifests/packages-$role.lock"
