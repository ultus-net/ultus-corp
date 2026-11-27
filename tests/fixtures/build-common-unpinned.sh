#!/usr/bin/env bash
# A build helper that names Containerfile.core without the pinned base argument.
set -euo pipefail
podman build -f Containerfile.core -t localhost/ultus-corp/core:local .
