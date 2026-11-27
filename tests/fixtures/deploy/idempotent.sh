#!/usr/bin/env bash
# A second run must not rewrite the record, or a retry would move the timestamp.
set -euo pipefail
mkdir -p /run/ultus-corp
printf '%s\n' "$DEPLOY_ID" > /run/ultus-corp/deployment-id
printf '%s\n' '{"role":"dns"}' > /run/ultus-corp/node.json
record=/var/lib/ultus-corp/deployments/$DEPLOY_ID.json

PATH=/fixtures:$PATH /usr/libexec/ultus-corp/finalize.sh "$DEPLOY_ID" > /dev/null
before=$(sha256sum "$record")
PATH=/fixtures:$PATH /usr/libexec/ultus-corp/finalize.sh "$DEPLOY_ID" > /dev/null
after=$(sha256sum "$record")
[ "$before" = "$after" ] || {
  echo "a second run rewrote the record"
  exit 1
}
