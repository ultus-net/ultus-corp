#!/usr/bin/env bash
# The dhcp role inside the image: the server config and the relay config, both
# from the renderer, and both refused when absent or invalid.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/common.sh
img=$(lab_image dhcp)

render_node() {
  python3 - "$1" <<'PY'
import json, pathlib, sys
sys.path.insert(0, "lab")
import render
spec = render.load("lab/lab.toml")
node = next(n for n in render.nodes_for(spec, "s2-dhcp") if n.name == sys.argv[1])
root = pathlib.Path("run/fixtures") / node.name
for path, content in render.managed_files(node, spec).items():
    target = root / path.lstrip("/")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
identity = root / "run/ultus-corp/node.json"
identity.parent.mkdir(parents=True, exist_ok=True)
identity.write_text(json.dumps(render.node_identity(node, spec)), encoding="utf-8")
PY
}

render_node dhcp-a
render_node relay-a

# $3 runs after the seed is copied and before the applier, so a test can model a
# deployment that delivered something wrong. $2 runs after the applier.
provision() {
  local node=$1 check=$2 setup=${3:-true}
  podman run --rm -v "$PWD/run/fixtures/$node:/seed:ro" "$img" bash -c "
    set -euo pipefail
    cp -a /seed/. /
    $setup
    /usr/libexec/ultus-corp/provision.sh
    $check
  "
}

assert_ok "kea installed"   podman run --rm "$img" rpm -q kea
assert_ok "dnsmasq installed" podman run --rm "$img" rpm -q dnsmasq
assert_ok "no kea config shipped" \
  podman run --rm "$img" test ! -e /etc/kea/kea-dhcp4.conf
assert_ok "no relay config shipped" \
  podman run --rm "$img" test ! -e /etc/ultus-corp/dhcp-relay.conf
assert_ok "applier installed" \
  podman run --rm "$img" test -x /usr/libexec/ultus-corp/provision.sh
assert_ok "provision unit enabled" \
  podman run --rm "$img" systemctl is-enabled ultus-provision.service
assert_ok "the vendor kea unit is not enabled" \
  podman run --rm "$img" bash -c '! systemctl is-enabled kea-dhcp4.service'
assert_ok "the vendor dnsmasq unit is not enabled" \
  podman run --rm "$img" bash -c '! systemctl is-enabled dnsmasq.service'
assert_ok "the dhcp health check is required" \
  podman run --rm "$img" test -x /etc/greenboot/check/required.d/50-dhcp-health.sh

assert_ok "server config names the pool" provision dhcp-a \
  'grep -q "10.200.10.100 - 10.200.10.199" /etc/kea/kea-dhcp4.conf'
assert_ok "server config names the relay" provision dhcp-a \
  'grep -q "10.200.10.254" /etc/kea/kea-dhcp4.conf'
assert_ok "server config sends no router option" provision dhcp-a \
  '! grep -q "routers" /etc/kea/kea-dhcp4.conf'
assert_ok "relay config names the server" provision relay-a \
  'grep -q "dhcp-relay=10.200.10.254,10.100.10.21" /etc/ultus-corp/dhcp-relay.conf'
assert_ok "relay config disables DNS" provision relay-a \
  'grep -q "^port=0$" /etc/ultus-corp/dhcp-relay.conf'

# The config must start the daemon, not only parse. The container has no init,
# so the applier skips the systemd handoff and the test starts Kea directly.
assert_ok "rendered kea config starts and answers status-get" podman run --rm \
  -v "$PWD/run/fixtures/dhcp-a:/seed:ro" "$img" bash -c '
    set -euo pipefail
    cp -a /seed/. /
    /usr/libexec/ultus-corp/provision.sh
    kea-dhcp4 -c /etc/kea/kea-dhcp4.conf >/tmp/kea.log 2>&1 &
    pid=$!
    # Kill the daemon on every exit path, so a failed probe never leaves it
    # running and a start failure still prints why.
    trap "kill $pid 2>/dev/null || true" EXIT
    for _ in $(seq 30); do
      if ! kill -0 "$pid" 2>/dev/null; then
        cat /tmp/kea.log >&2
        exit 1
      fi
      if [ -S /var/run/kea/kea4-ctrl-socket ]; then
        break
      fi
      sleep 1
    done
    if [ ! -S /var/run/kea/kea4-ctrl-socket ]; then
      cat /tmp/kea.log >&2
      exit 1
    fi
    python3 - <<PY
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect("/var/run/kea/kea4-ctrl-socket")
s.sendall(json.dumps({"command": "status-get", "service": ["dhcp4"]}).encode() + b"\n")
data = b""
try:
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
except socket.timeout:
    pass
reply = json.loads(data)
sys.exit(0 if reply.get("result") == 0 and reply["arguments"]["sockets"]["status"] == "ready" else 1)
PY
    kill "$pid"
    wait "$pid" || true
  '

# $3 is the setup, so the damage lands before the applier reads the file.
assert_fails "invalid kea config fails closed" provision dhcp-a true \
  'printf "\nnot json\n" > /etc/kea/kea-dhcp4.conf'
assert_fails "invalid relay config fails closed" provision relay-a true \
  'printf "\nnot dnsmasq\n" > /etc/ultus-corp/dhcp-relay.conf'
assert_fails "an unknown profile fails closed" provision relay-a true \
  'python3 -c "import json; p=\"/run/ultus-corp/node.json\"; d=json.load(open(p)); d[\"profile\"]=\"other\"; json.dump(d, open(p, \"w\"))"'

# A required check must fail when the service it names is absent. A record
# marks the host as deployed, which is the case the check must judge. The
# applier runs, but the container has no init, so neither daemon is started.
assert_fails "the server check fails with no kea" provision dhcp-a \
  'mkdir -p /var/lib/ultus-corp/deployments && : > /var/lib/ultus-corp/deployments/deployed.json && ULTUS_HEALTH_TRIES=1 /etc/greenboot/check/required.d/50-dhcp-health.sh'
assert_fails "the relay check fails with no relay" provision relay-a \
  'mkdir -p /var/lib/ultus-corp/deployments && : > /var/lib/ultus-corp/deployments/deployed.json && ULTUS_HEALTH_TRIES=1 /etc/greenboot/check/required.d/50-dhcp-health.sh'

finish
