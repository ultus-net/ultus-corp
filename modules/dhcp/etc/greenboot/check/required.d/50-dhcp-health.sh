#!/usr/bin/env bash
set -euo pipefail

. /usr/libexec/ultus-corp/deployed.sh
deployment_gate

node=/run/ultus-corp/node.json
tries=${ULTUS_HEALTH_TRIES:-30}
profile=$(python3 - "$node" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("profile") or "")
except (OSError, ValueError):
    print("")
PY
)

# Kea answers on its control socket once the DHCPv4 service has bound the
# interfaces and opened the socket. A process that is merely running is not
# enough: a config that parses can still leave the service not ready.
kea_ready() {
  python3 - <<'PY'
import json, socket, sys

path = "/var/run/kea/kea4-ctrl-socket"
try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    sock.connect(path)
    sock.sendall(json.dumps({"command": "status-get", "service": ["dhcp4"]}).encode() + b"\n")
    data = b""
    while b"\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
    reply = json.loads(data)
except (OSError, ValueError) as error:
    print(f"kea did not answer on {path}: {error}", file=sys.stderr)
    sys.exit(1)

if reply.get("result") != 0 or reply.get("arguments", {}).get("sockets", {}).get("status") != "ready":
    print(f"kea is not ready: {reply}", file=sys.stderr)
    sys.exit(1)
PY
}

case "$profile" in
server)
  for _ in $(seq "$tries"); do
    if kea_ready; then
      exit 0
    fi
    sleep 1
  done
  echo "kea did not report its control socket ready after ${tries}s" >&2
  exit 1
  ;;
relay)
  for _ in $(seq "$tries"); do
    if systemctl is-active --quiet ultus-dhcp-relay.service \
      && [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ]; then
      exit 0
    fi
    sleep 1
  done
  echo "the relay did not come up with ip_forward on after ${tries}s" >&2
  exit 1
  ;;
*)
  echo "profile '$profile' is neither server nor relay; cannot check dhcp health" >&2
  exit 1
  ;;
esac
