#!/usr/bin/env bash
set -euo pipefail

. /usr/libexec/ultus-corp/deployed.sh
deployment_gate

node=/run/ultus-corp/node.json
# A delivered identity that names no DHCP interface can never satisfy the check,
# so the shape fails at once instead of waiting out a lease that cannot come.
python3 - "$node" <<'PY'
import json, sys
identity = json.load(open(sys.argv[1]))
if not identity.get("dhcp_interfaces"):
    raise SystemExit(f"the identity at {sys.argv[1]} names no DHCP interface")
PY

# The relay and Kea may still be deploying when this guest writes its record, so
# the default wait covers a full two minutes of neighbour boot time.
for _ in $(seq "${ULTUS_HEALTH_TRIES:-120}"); do
  if python3 - "$node" <<'PY'
import ipaddress, json, subprocess, sys
identity = json.load(open(sys.argv[1]))
nets = [ipaddress.ip_network(i["cidr"]) for i in identity["dhcp_interfaces"]]
links = json.loads(subprocess.run(
    ["ip", "-4", "-j", "addr", "show"],
    capture_output=True, text=True, check=True,
).stdout)
for link in links:
    for info in link.get("addr_info", []):
        if any(ipaddress.ip_address(info["local"]) in net for net in nets):
            sys.exit(0)
sys.exit(1)
PY
  then
    exit 0
  fi
  sleep 1
done

echo "no DHCP lease on the interface named by $node after ${ULTUS_HEALTH_TRIES:-120}s" >&2
exit 1
