#!/usr/bin/env bash
# The unit instance and the delivered id must agree, or the wrong unit ran.
set -euo pipefail
mkdir -p /run/ultus-corp
printf '%s\n' '11111111-1111-4111-8111-111111111111' > /run/ultus-corp/deployment-id
printf '%s\n' '{"role":"dns"}' > /run/ultus-corp/node.json

if PATH=/fixtures:$PATH /usr/libexec/ultus-corp/finalize.sh "$DEPLOY_ID"; then
  echo "a mismatched deployment id was accepted"
  exit 1
fi
