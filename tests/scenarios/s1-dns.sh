#!/usr/bin/env bash
# Two authoritative nodes: the primary owns the zone, the secondary copies it.
# Then the deployment and managed-file gates: one record, a consumed seed, and
# the same checksums after a second boot and after a hand edit.
set -euo pipefail
cd "$(dirname "$0")/../.."
. tests/lib.sh

lab up s1-dns
addresses=$(python3 - <<'PY'
import json, os
state = json.load(open(os.environ["RUN"] + "/s1-dns/state.json"))
print(state["nodes"]["dns-a"]["address"], state["nodes"]["dns-b"]["address"])
PY
)
read -r addr_a addr_b <<< "$addresses"
id_a=$(python3 -c 'import json,os;print(json.load(open(os.environ["RUN"] + "/s1-dns/state.json"))["nodes"]["dns-a"]["deployment_id"])')
digest_a=$(python3 -c 'import json,sys;print(json.load(open("run/s1-dns/state.json"))["deployments"][sys.argv[1]]["image_digest"])' "$id_a")

guest() {
  local addr=$1
  shift
  ssh -i lab-secrets/id_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=5 "root@$addr" "$@"
}

manifest_ok() {
  local addr=$1 node=$2
  guest "$addr" 'sha256sum -c -' < "run/s1-dns/render/$node.managed-files.sha256"
}

assert_eq "primary domain running" "running" "$(virsh domstate ultus-s1-dns-dns-a)"
assert_eq "secondary domain running" "running" "$(virsh domstate ultus-s1-dns-dns-b)"

# The primary's zone carries its own address, not the build-time placeholder.
assert_ok "primary answers its own record" timeout 300 \
  bash -c "until dig +short +time=2 +tries=1 @$addr_a dns-a.lab.internal | grep -qx $addr_a; do sleep 2; done"
# The secondary answers the primary's address only if the zone was copied: its
# shipped copy is deleted at provisioning, so a local rewrite cannot fake this.
assert_ok "secondary answers the copied zone" timeout 300 \
  bash -c "until dig +short +time=2 +tries=1 @$addr_b dns-a.lab.internal | grep -qx $addr_a; do sleep 2; done"
assert_eq "secondary does not serve its own address" "" \
  "$(dig +short +time=2 +tries=1 @$addr_b dns-a.lab.internal | grep -x "$addr_b" || true)"

assert_ok "primary answers authoritatively" \
  bash -c "dig +norec +time=2 +tries=1 @$addr_a lab.internal SOA | grep -q 'flags:.* aa;'"
assert_ok "ipa subdomain is delegated" \
  bash -c "dig +time=2 +tries=1 @$addr_a ipa.lab.internal NS | grep -qE '^ipa\.lab\.internal\..*IN[[:space:]]+NS[[:space:]]+ipa\.lab\.internal\.'"

# Gate 10, first leg: the bytes the seed carried are the bytes on disk.
assert_ok "primary matches its manifest" manifest_ok "$addr_a" dns-a
assert_ok "secondary matches its manifest" manifest_ok "$addr_b" dns-b

# Gate 11: one record for the deployment the harness delivered, and no second
# copy. The record is the guest's own account of the digest it booted.
record=/var/lib/ultus-corp/deployments/$id_a.json
assert_eq "guest holds one record" "1" \
  "$(guest "$addr_a" 'ls -1 /var/lib/ultus-corp/deployments/*.json | wc -l')"
assert_eq "record is keyed by the deployment id" "$id_a" \
  "$(guest "$addr_a" "basename $record .json")"
assert_eq "record has the four contract keys" "completed_at,id,image_digest,role" \
  "$(guest "$addr_a" "python3 -c \"import json;print(','.join(sorted(json.load(open('$record')))))\"")"
assert_eq "record names the delivered role" "dns" \
  "$(guest "$addr_a" "python3 -c \"import json;print(json.load(open('$record'))['role'])\"")"
assert_eq "record names the booted digest" "$digest_a" \
  "$(guest "$addr_a" "python3 -c \"import json;print(json.load(open('$record'))['image_digest'])\"")"
assert_eq "finalize is active for this deployment" "active" \
  "$(guest "$addr_a" "systemctl is-active ultus-deploy-finalize@$id_a.service")"
# The seed and its cache are gone: the deployment consumed them, not teardown.
assert_ok "cloud-init instance cache is scrubbed" \
  guest "$addr_a" test ! -e /var/lib/cloud/instance
assert_ok "the seed is marked consumed" python3 - <<'PY'
import json
state = json.load(open("run/s1-dns/state.json"))
seeds = [r for r in state["resources"] if r["kind"] in {"seed", "seediso"}]
assert seeds, state["resources"]
assert all(r.get("consumed") for r in seeds), seeds
PY
assert_ok "the ejected seed file is gone" \
  bash -c "! test -e run/s1-dns/ultus-s1-dns-dns-a-seed.iso"

record_before=$(guest "$addr_a" "sha256sum $record")

# Gate 10, second leg: a reboot must not rewrite a managed file, and gate 11
# requires the record to survive it unchanged.
virsh reboot ultus-s1-dns-dns-a
assert_ok "primary answers after a second boot" timeout 300 \
  bash -c "until dig +short +time=2 +tries=1 @$addr_a dns-a.lab.internal | grep -qx $addr_a; do sleep 2; done"
assert_ok "primary matches its manifest after a second boot" manifest_ok "$addr_a" dns-a
assert_eq "the record is unchanged after a second boot" "$record_before" \
  "$(guest "$addr_a" "sha256sum $record")"
assert_eq "the second boot adds no record" "1" \
  "$(guest "$addr_a" 'ls -1 /var/lib/ultus-corp/deployments/*.json | wc -l')"
# The condition skips the recorded id, so the unit is not started again.
assert_eq "finalize does not start again for the id" "inactive" \
  "$(guest "$addr_a" "systemctl is-active ultus-deploy-finalize@$id_a.service")"

# The comparison has teeth: a hand edit of one managed file must fail it.
guest "$addr_a" 'cp /etc/named.conf /tmp/named.conf.good && printf "\n// hand edit\n" >> /etc/named.conf'
assert_fails "a hand-edited managed file fails the manifest" manifest_ok "$addr_a" dns-a
guest "$addr_a" 'cat /tmp/named.conf.good > /etc/named.conf'
assert_ok "restoring the file passes the manifest again" manifest_ok "$addr_a" dns-a

# The secondary serves from its copy while the primary is gone.
virsh suspend ultus-s1-dns-dns-a
assert_ok "secondary answers without the primary" timeout 120 \
  bash -c "until dig +short +time=2 +tries=1 @$addr_b dns-a.lab.internal | grep -qx $addr_a; do sleep 2; done"
virsh resume ultus-s1-dns-dns-a
assert_ok "primary answers again after resume" timeout 120 \
  bash -c "until dig +short +time=2 +tries=1 @$addr_a dns-a.lab.internal | grep -qx $addr_a; do sleep 2; done"

lab down s1-dns
assert_ok "no domain left" bash -c "! virsh list --all --name | grep -q ultus-s1-dns"
assert_ok "no network left" bash -c "! virsh net-list --all --name | grep -q ultus-s1-dns"
assert_ok "seed removed"   bash -c "! test -e $RUN/s1-dns/seed"

finish
