#!/usr/bin/env bash
# Close one deployment: record it, then scrub the one-time material.
#
# The seed carries no secret beyond the lab's own public key, so the only
# one-time material is cloud-init's cached instance data. `/var` survives an
# image rollback, so the record is keyed by deployment id rather than appended.
set -euo pipefail

id=${1:?usage: finalize.sh <deployment-id>}
node=/run/ultus-corp/node.json
idfile=/run/ultus-corp/deployment-id
dir=/var/lib/ultus-corp/deployments
record=$dir/$id.json

fail() {
  echo "finalize: $*" >&2
  exit 1
}

# The unit's condition already skips a second start for this id. This guard
# makes a direct run idempotent too, so a retry cannot rewrite the timestamp.
if [ -e "$record" ]; then
  echo "finalize: $id is already recorded"
  exit 0
fi

# The instance name comes from the unit, so an id that is not a plain UUIDv4
# could name a path outside the record directory.
if ! python3 - "$id" <<'PY'
import re, sys
pattern = r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
sys.exit(0 if re.match(pattern, sys.argv[1]) else 1)
PY
then
  fail "'$id' is not a lowercase UUIDv4 deployment id"
fi

[ -s "$idfile" ] || fail "$idfile is missing; the deployment did not deliver it"
delivered=$(tr -d '[:space:]' < "$idfile")
[ "$delivered" = "$id" ] || fail "unit instance $id does not match the delivered id $delivered"
[ -s "$node" ] || fail "$node is missing; the deployment did not deliver it"

# `bootc status` is the only source for the running digest. A container or a
# host that was not installed by bootc reports no booted deployment, and that is
# a failed deployment, not a record with an empty digest.
status=$(bootc status --json --format-version=1) || fail "bootc status failed"
digest=$(printf '%s' "$status" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["status"]["booted"]["image"]["imageDigest"])
except (KeyError, TypeError):
    raise SystemExit("no booted image digest in bootc status")
') || fail "bootc reports no booted image digest"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "bootc digest is not sha256:<64 hex>: $digest"

role=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["role"])' "$node") \
  || fail "cannot read the role from $node"

mkdir -p "$dir"
chmod 0755 "$dir"
tmp=$(mktemp "$dir/.record-XXXXXX")
trap 'python3 -c "import pathlib,sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)" "$tmp"' EXIT
python3 - "$tmp" "$id" "$digest" "$role" <<'PY'
import json, sys
from datetime import datetime, timezone

target, deployment, digest, role = sys.argv[1:5]
record = {
    "id": deployment,
    "image_digest": digest,
    "role": role,
    "completed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(target, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
chmod 0644 "$tmp"
mv -f "$tmp" "$record"
trap - EXIT

# Cached user-data would otherwise outlive the deployment it belongs to.
python3 - <<'PY'
import shutil
for path in ("/var/lib/cloud/instance", "/var/lib/cloud/instances"):
    shutil.rmtree(path, ignore_errors=True)
PY

echo "finalize: recorded $id for role $role at $digest"
