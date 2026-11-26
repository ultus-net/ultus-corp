#!/usr/bin/env bash
# Exercise provision.sh inside the role image, for both the primary and the
# secondary of a scenario. No hypervisor: the node file is the seed's payload.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/common.sh
img=$(lab_image dns)
mkdir -p run/fixtures

# The fixture is the renderer's own payload, so a change to the seed shape
# reaches this gate without a second copy of the schema.
node_file() {
  python3 - "$1" <<'PY'
import sys
sys.path.insert(0, "lab")
import render
spec = render.load("lab/lab.toml")
node = next(n for n in render.nodes_for(spec, "s1-dns") if n.name == sys.argv[1])
import json
print(json.dumps(render.node_payload(node, spec)))
PY
}

node_file dns-a > run/fixtures/dns-a.json
node_file dns-b > run/fixtures/dns-b.json

provision() {
  local node=$1 check=$2
  podman run --rm -v "$PWD/run/fixtures/$node.json:/run/ultus-corp/node.json:ro" \
    "$img" bash -c "/usr/libexec/ultus-corp/provision.sh && $check"
}

assert_ok "primary transfers to its secondary" provision dns-a \
  'grep -q "allow-transfer { 10.100.10.12; }" /etc/named.conf'
assert_ok "primary notifies its secondary" provision dns-a \
  'grep -q "also-notify { 10.100.10.12; }" /etc/named.conf'
assert_ok "primary owns the zone file" provision dns-a \
  'grep -q "^dns-a   IN  A   10.100.10.11$" /var/named/lab.internal.zone'
assert_ok "primary keeps the delegation" provision dns-a \
  'grep -q "^ipa     IN  NS  ipa.lab.internal.$" /var/named/lab.internal.zone'
assert_ok "primary resolver forwards to itself" provision dns-a \
  'grep -q "forward-addr: 10.100.10.11" /etc/unbound/unbound.conf'

assert_ok "secondary copies from the primary" provision dns-b \
  'grep -q "masters { 10.100.10.11; }" /etc/named.conf'
assert_ok "secondary is not a primary" provision dns-b \
  'grep -q "type secondary;" /etc/named.conf'
# A shipped copy would carry the same serial as the master, so BIND would keep
# it instead of transferring.
assert_ok "secondary carries no zone file" provision dns-b \
  '! test -e /var/named/lab.internal.zone'
assert_ok "secondary resolver forwards to itself" provision dns-b \
  'grep -q "forward-addr: 10.100.10.12" /etc/unbound/unbound.conf'

finish
