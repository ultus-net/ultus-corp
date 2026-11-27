#!/usr/bin/env bash
set -euo pipefail

. /usr/libexec/ultus-corp/deployed.sh
deployment_gate

node=/run/ultus-corp/node.json
# A delivered identity that names no DHCP interface can never satisfy the check,
# and a malformed one raises a traceback instead of a verdict. Both fail at once
# with one message that names the path and the defect, so the retry loop below
# can trust the shape it reads.
python3 - "$node" <<'PY'
import ipaddress, json, sys

path = sys.argv[1]

def fail(message):
    sys.stderr.write(f"client health check: {message}\n")
    raise SystemExit(1)

try:
    with open(path, encoding="utf-8") as handle:
        identity = json.load(handle)
except json.JSONDecodeError:
    fail(f"the identity at {path} is not valid JSON")
except (OSError, UnicodeDecodeError):
    fail(f"the identity at {path} is not readable")

if not isinstance(identity, dict) or "dhcp_interfaces" not in identity:
    fail(f"the identity at {path} names no DHCP interface")
interfaces = identity["dhcp_interfaces"]
if not isinstance(interfaces, list) or not interfaces:
    fail(f"the identity at {path} has no dhcp_interfaces list")

for index, interface in enumerate(interfaces):
    if not isinstance(interface, dict) or not isinstance(interface.get("cidr"), str):
        fail(f"dhcp_interfaces[{index}] at {path} is not an object with a string cidr")
    try:
        ipaddress.ip_network(interface["cidr"])
    except ValueError:
        fail(f"dhcp_interfaces[{index}].cidr at {path} is not a network: {interface['cidr']}")
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
