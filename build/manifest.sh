#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. build/common.sh

role=${1:?usage: build/manifest.sh <role>}
manifest "$role"
echo "build/out/install-$role.txt"
