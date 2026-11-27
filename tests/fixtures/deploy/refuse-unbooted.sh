#!/usr/bin/env bash
# `bootc status` is the only source for the running digest. A container has no
# booted deployment, and that is a failed deployment, not an empty record.
set -euo pipefail
mkdir -p /run/ultus-corp
printf '%s\n' "$DEPLOY_ID" > /run/ultus-corp/deployment-id
printf '%s\n' '{"role":"dns"}' > /run/ultus-corp/node.json

if /usr/libexec/ultus-corp/finalize.sh "$DEPLOY_ID"; then
  echo "a host with no booted image was accepted"
  exit 1
fi
test ! -d /var/lib/ultus-corp/deployments \
  || test -z "$(ls -A /var/lib/ultus-corp/deployments)"
