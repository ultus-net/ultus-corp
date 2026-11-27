#!/usr/bin/env bash
# A build helper that passes the base argument but reads the wrong pin file.
set -euo pipefail
base_ref() { head -n 1 manifests/base-draft.txt; }
podman build --build-arg BASE="$(base_ref)" -f Containerfile.core \
  -t localhost/ultus-corp/core:local .
