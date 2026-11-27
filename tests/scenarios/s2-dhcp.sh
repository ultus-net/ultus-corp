#!/usr/bin/env bash
# A relayed lease that survives a Kea restart, a relay restart and a client
# reboot. The relay is the only path: stop it and the client gets no address.
set -euo pipefail
cd "$(dirname "$0")/../.."
. tests/lib.sh

lab up s2-dhcp

state=$RUN/s2-dhcp/state.json
server=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["nodes"]["dhcp-a"]["address"])' "$state")
relay=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["nodes"]["relay-a"]["address"])' "$state")
client=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["nodes"]["client-a"]["address"])' "$state")

guest() {
  local addr=$1
  shift
  ssh -i lab-secrets/id_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=5 "root@$addr" "$@"
}

branch_dev() {
  guest "$client" "ip -4 -o addr show | awk '\$4 ~ /^10\\.200\\.10\\./ {print \$2; exit}'"
}

branch_addr() {
  guest "$client" "ip -4 -o addr show | awk '\$4 ~ /^10\\.200\\.10\\./ {print \$4; exit}' | cut -d/ -f1"
}

renew() {
  local dev=$1
  [ -n "$dev" ] || { echo "no branch device to renew" >&2; return 1; }
  guest "$client" "nmcli device disconnect '$dev'; nmcli --wait 10 device connect '$dev' || true"
}

# The guest Python lives in a fixture, so no heredoc quoting reaches this file.
# `ssh root@host python3 -` reads it from stdin and prints the lease list.
leases() {
  guest "$server" 'python3 -' < tests/fixtures/kea-leases.py
}

wait_branch_addr() {
  local want=${1:-} addr
  for _ in $(seq 60); do
    addr=$(branch_addr 2>/dev/null || true)
    if [ -n "$addr" ] && { [ -z "$want" ] || [ "$addr" = "$want" ]; }; then
      return 0
    fi
    sleep 2
  done
  echo "no branch address${want:+ equal to $want} within 120s" >&2
  return 1
}

assert_eq "server domain running" "running" "$(virsh domstate ultus-s2-dhcp-dhcp-a)"
assert_eq "relay domain running" "running" "$(virsh domstate ultus-s2-dhcp-relay-a)"
assert_eq "client domain running" "running" "$(virsh domstate ultus-s2-dhcp-client-a)"

wait_branch_addr
leased=$(branch_addr)
dev=$(branch_dev)
expected_mac=$(python3 -c 'import sys; sys.path.insert(0, "lab"); import render; print(render.interface_mac("s2-dhcp", "client-a", "lan"))')

last=${leased##*.}
assert_ok "the lease is in the pool" test "$last" -ge 100 -a "$last" -le 199

# Live proof: Kea holds the lease, for this address, in subnet 1.
assert_ok "kea holds the lease" python3 -c '
import json, sys
leases = json.loads(sys.argv[1])
sys.exit(0 if any(l["ip-address"] == sys.argv[2] and l["subnet-id"] == 1 for l in leases) else 1)
' "$(leases)" "$leased"

# A clean restart flushes the memfile and reloads it. The CSV row is the durable
# proof; it cannot exist before the first clean shutdown.
guest "$server" 'systemctl restart kea-dhcp4.service'
assert_ok "kea answers after a restart" timeout 60 bash -c \
  "until ssh -i lab-secrets/id_ed25519 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes root@$server \
    'systemctl is-active --quiet kea-dhcp4.service'; do sleep 2; done"
csv_row=$(guest "$server" "grep '^$leased,' /var/lib/kea/kea-leases4.csv" || true)
assert_eq "the lease is in the durable store" "yes" \
  "$([ -n "$csv_row" ] && echo yes || echo no)"
assert_eq "the durable lease names the client MAC" "$expected_mac" \
  "$(cut -d, -f2 <<<"$csv_row")"
assert_ok "the live lease survives the restart" python3 -c '
import json, sys
leases = json.loads(sys.argv[1])
sys.exit(0 if any(l["ip-address"] == sys.argv[2] for l in leases) else 1)
' "$(leases)" "$leased"

renew "$dev"
wait_branch_addr "$leased"
assert_eq "the same address after a renew" "$leased" "$(branch_addr)"

guest "$relay" 'systemctl restart ultus-dhcp-relay.service'
assert_ok "the relay answers after a restart" timeout 60 bash -c \
  "until ssh -i lab-secrets/id_ed25519 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes root@$relay \
    'systemctl is-active --quiet ultus-dhcp-relay.service'; do sleep 2; done"
renew "$dev"
wait_branch_addr "$leased"
assert_eq "the same address after a relay restart" "$leased" "$(branch_addr)"

virsh reboot ultus-s2-dhcp-client-a
assert_ok "client returns after a reboot" timeout 300 bash -c \
  "until ssh -i lab-secrets/id_ed25519 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 \
    root@$client true; do sleep 2; done"
wait_branch_addr "$leased"
assert_eq "the same address after a client reboot" "$leased" "$(branch_addr)"
assert_ok "the client health check passes after the reboot" \
  guest "$client" /etc/greenboot/check/required.d/50-client-health.sh

# Negative control: the relay is the only path to Kea. With it stopped, a
# disconnect and reconnect drops the address and the client cannot get one back.
# NetworkManager may retry with the cached lease, but it never assigns an address
# without a server reply. If an address survives this step, the control is not
# proving the relay path: stop and report it, never weaken the assertion.
guest "$relay" 'systemctl stop ultus-dhcp-relay.service'
renew "$dev"
sleep 20
assert_eq "no branch lease without the relay" "" "$(branch_addr)"
guest "$relay" 'systemctl start ultus-dhcp-relay.service'
renew "$dev"
wait_branch_addr "$leased"
assert_eq "the lease returns when the relay returns" "$leased" "$(branch_addr)"

lab down s2-dhcp
assert_ok "no domain left" bash -c "! virsh list --all --name | grep -q ultus-s2-dhcp"
assert_ok "no network left" bash -c "! virsh net-list --all --name | grep -q ultus-s2-dhcp"
assert_ok "seed removed" bash -c "! test -e $RUN/s2-dhcp/seed"

finish
