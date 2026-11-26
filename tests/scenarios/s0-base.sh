#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
. tests/lib.sh

lab up s0-base
addr=$(python3 -c 'import json,os;print(json.load(open(os.environ["RUN"] + "/s0-base/state.json"))["nodes"]["base-a"]["address"])')

assert_eq "domain running" "running" "$(virsh domstate ultus-s0-base-base-a)"
assert_ok "guest reachable" timeout 180 \
  bash -c "until ping -c1 -W1 $addr >/dev/null; do sleep 2; done"
# A ping proves the NIC, not the boot: provisioning and the services start
# after the network, so every service assertion waits for its own answer.
assert_ok "cloud-init finished" timeout 300 ssh -i lab-secrets/id_ed25519 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
  "root@$addr" 'cloud-init status --wait | grep -q "status: done"'
assert_ok "named answers the lab zone" timeout 120 \
  bash -c "until dig +short +time=2 +tries=1 @$addr base-a.lab.internal | grep -q $addr; do sleep 2; done"
assert_eq "name resolves to the guest" "$addr" \
  "$(dig +short +time=2 +tries=1 @$addr base-a.lab.internal | tail -1)"
assert_eq "absent name is NXDOMAIN" "NXDOMAIN" \
  "$(dig +time=2 +tries=1 @$addr absent.lab.internal \
     | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1)"
assert_ok "the node's own health check passes" timeout 120 ssh -i lab-secrets/id_ed25519 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
  "root@$addr" '/etc/greenboot/check/required.d/50-dns-health.sh'
assert_ok "no libvirt dnsmasq on the segment" \
  bash -c "! pgrep -af '[d]nsmasq.*ultus-s0-base'"

lab down s0-base
assert_ok "no domain left" bash -c "! virsh list --all --name | grep -q ultus-s0-base"
assert_ok "seed removed"   bash -c "! test -e $RUN/s0-base/seed"

finish
