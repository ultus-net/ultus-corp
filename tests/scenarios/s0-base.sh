#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
. tests/lib.sh

lab up s0-base
addr=$(python3 -c 'import json,os;print(json.load(open(os.environ["RUN"] + "/s0-base/state.json"))["nodes"]["base-a"]["address"])')

assert_eq "domain running" "running" "$(virsh domstate ultus-s0-base-base-a)"
assert_ok "guest reachable" timeout 120 bash -c "until ping -c1 -W1 $addr; do sleep 2; done"
assert_eq "name resolves to the guest" "$addr" "$(dig +short +time=2 @$addr base-a.lab.internal | tail -1)"
assert_eq "NXDOMAIN is empty" "" "$(dig +short +time=2 @$addr absent.lab.internal)"
assert_ok "cloud-init finished" ssh -i lab-secrets/id_ed25519 -o StrictHostKeyChecking=no \
  "root@$addr" 'cloud-init status --wait | grep -q "status: done"'
assert_ok "no libvirt dnsmasq on the segment" \
  bash -c "! pgrep -af '[d]nsmasq.*ultus-s0-base'"
lab down s0-base
assert_ok "no domain left" bash -c "! virsh list --all --name | grep -q ultus-s0-base"
assert_ok "seed removed"   bash -c "! test -e $RUN/s0-base/seed"

finish
