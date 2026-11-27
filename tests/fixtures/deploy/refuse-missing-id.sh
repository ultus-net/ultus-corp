#!/usr/bin/env bash
# A seed that delivered no deployment id cannot name a deployment.
set -euo pipefail
mkdir -p /run/ultus-corp
printf '%s\n' '{"role":"dns"}' > /run/ultus-corp/node.json

if PATH=/fixtures:$PATH /usr/libexec/ultus-corp/finalize.sh "$DEPLOY_ID"; then
  echo "a missing deployment id was accepted"
  exit 1
fi
