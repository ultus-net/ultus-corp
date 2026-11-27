#!/usr/bin/env bash
# A delivered deployment produces exactly one record with the contract keys.
set -euo pipefail
mkdir -p /run/ultus-corp
printf '%s\n' "$DEPLOY_ID" > /run/ultus-corp/deployment-id
printf '%s\n' '{"name":"dns-a","fqdn":"dns-a.lab.internal","role":"dns","scenario":"s1-dns","primary":true}' \
  > /run/ultus-corp/node.json

PATH=/fixtures:$PATH /usr/libexec/ultus-corp/finalize.sh "$DEPLOY_ID"
python3 - "$DEPLOY_ID" "$DEPLOY_DIGEST" <<'PY'
import json, os, sys

directory = "/var/lib/ultus-corp/deployments"
records = os.listdir(directory)
assert records == [f"{sys.argv[1]}.json"], records
record = json.load(open(os.path.join(directory, records[0])))
assert set(record) == {"id", "image_digest", "role", "completed_at"}, record
assert record["id"] == sys.argv[1], record
assert record["role"] == "dns", record
assert record["image_digest"] == sys.argv[2], record
assert record["completed_at"].endswith("Z"), record
PY
