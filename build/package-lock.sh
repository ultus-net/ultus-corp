#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. build/common.sh

[ "${1:-}" = "resolve" ] || { echo "usage: build/package-lock.sh resolve <role>"; exit 1; }
role=${2:?usage: build/package-lock.sh resolve <role>}

build_role "$role"
podman run --rm "$(lab_image "$role")" rpm -qa --qf '%{NAME}-%{EVR}.%{ARCH}\n' | sort \
  > "manifests/packages-$role.lock"
echo "manifests/packages-$role.lock"
