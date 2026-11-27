#!/usr/bin/env bash
# Exercise provision.sh inside the role image, for both the primary and the
# secondary of a scenario. No hypervisor: the fixture is the renderer's own
# output, which is also what the seed carries.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/common.sh
img=$(lab_image dns)

# Each fixture mirrors the guest's absolute paths, so the test copies the same
# bytes to the same places cloud-init would.
render_node() {
  python3 - "$1" <<'PY'
import pathlib, sys, json
sys.path.insert(0, "lab")
import render
spec = render.load("lab/lab.toml")
node = next(n for n in render.nodes_for(spec, "s1-dns") if n.name == sys.argv[1])
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

render_node dns-a
render_node dns-b
# Model a file an earlier deployment left behind: the seed does not carry it,
# so it can only arrive if the applier fails to clear it.
mkdir -p run/fixtures/dns-b/var/named
cp run/fixtures/dns-a/var/named/lab.internal.zone \
  run/fixtures/dns-b/var/named/lab.internal.zone

# $3 runs after the seed is copied and before the applier, so a test can model a
# deployment that delivered something wrong.
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

assert_ok "primary transfers to its secondary" provision dns-a \
  'grep -q "allow-transfer { 10.100.10.12; }" /etc/named.conf'
assert_ok "primary notifies its secondary" provision dns-a \
  'grep -q "also-notify { 10.100.10.12; }" /etc/named.conf'
assert_ok "primary owns the zone file" provision dns-a \
  'grep -q "^dns-a   IN  A   10.100.10.11$" /var/named/lab.internal.zone'
assert_ok "primary keeps the delegation" provision dns-a \
  'grep -q "^ipa   IN  NS  ipa.lab.internal.$" /var/named/lab.internal.zone'
assert_ok "primary resolver forwards to itself" provision dns-a \
  'grep -q "forward-addr: 10.100.10.11" /etc/unbound/unbound.conf'
# unbound-checkconf accepts a chroot the daemon cannot start inside, so the
# rendered resolver is started rather than only parsed.
assert_ok "rendered resolver starts and binds loopback" podman run --rm \
  -v "$PWD/run/fixtures/dns-a:/seed:ro" "$img" bash -c '
    set -euo pipefail
    cp -a /seed/. /
    /usr/libexec/ultus-corp/provision.sh
    unbound -d &
    pid=$!
    sleep 3
    kill -0 "$pid" || { echo "unbound exited at startup"; exit 1; }
    ss -lun | grep -q "127.0.0.1:53" || { echo "no listener on 127.0.0.1:53"; exit 1; }
    kill "$pid"
  '

# The applier installs the delivered bytes unchanged. A rewrite here would make
# the guest disagree with the manifest the deployment gate compares against.
assert_ok "applied bytes match the delivered bytes" podman run --rm \
  -v "$PWD/run/fixtures/dns-a:/seed:ro" "$img" bash -c '
    set -euo pipefail
    cp -a /seed/. /
    before=$(sha256sum /etc/named.conf /etc/unbound/unbound.conf /var/named/lab.internal.zone)
    /usr/libexec/ultus-corp/provision.sh
    after=$(sha256sum /etc/named.conf /etc/unbound/unbound.conf /var/named/lab.internal.zone)
    [ "$before" = "$after" ] || { echo "the applier rewrote a managed file"; exit 1; }
  '

# A primary that received no zone still passes a syntax check, so without this
# case the applier could start an empty name space and the gate would not know.
assert_fails "primary with no zone fails closed" provision dns-a true \
  "python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)' /var/named/lab.internal.zone"

# The applier validates the delivered file, so a bad deployment fails there and
# not thirty seconds later in the health check.
assert_fails "invalid delivered config fails closed" provision dns-a true \
  "printf '\nthis is not bind syntax\n' >> /etc/named.conf"

assert_ok "secondary copies from the primary" provision dns-b \
  'grep -q "masters { 10.100.10.11; }" /etc/named.conf'
assert_ok "secondary is not a primary" provision dns-b \
  'grep -q "type secondary;" /etc/named.conf'
assert_ok "secondary deletes a stale zone" provision dns-b \
  '! test -e /var/named/lab.internal.zone'
assert_ok "secondary resolver forwards to itself" provision dns-b \
  'grep -q "forward-addr: 10.100.10.12" /etc/unbound/unbound.conf'

# The image ships no managed configuration, so a deployment that delivers none
# must fail before named starts rather than fall back to a vendor default.
assert_fails "empty configuration fails closed" podman run --rm \
  -v /dev/null:/etc/named.conf:ro "$img" /usr/libexec/ultus-corp/provision.sh

finish
