#!/usr/bin/env bash
set -euo pipefail

. /usr/libexec/ultus-corp/deployed.sh
deployment_gate

node=/run/ultus-corp/node.json
# The relay and Kea may still be deploying when this guest writes its record, so
# the default wait covers a full two minutes of neighbour boot time.
for _ in $(seq "${ULTUS_HEALTH_TRIES:-120}"); do
  if python3 - "$node" <<'PY'
import ipaddress, json, subprocess, sys
identity = json.load(open(sys.argv[1]))
nets = [ipaddress.ip_network(i["cidr"]) for i in identity.get("dhcp_interfaces", [])]
if not nets:
    raise SystemExit("the identity names no DHCP interface")
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
