#!/usr/bin/env bash
# Two authoritative nodes: the primary owns the zone, the secondary copies it.
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
