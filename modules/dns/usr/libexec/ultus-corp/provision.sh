#!/usr/bin/env bash
set -euo pipefail

node=/run/ultus-corp/node.json
[ -s "$node" ] || { echo "provision: $node is missing" >&2; exit 1; }

read -r name address secondary < <(python3 - "$node" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data["name"], data["interfaces"][0]["address"], data.get("secondary", ""))
PY
)

python3 - "$node" /etc/named.conf <<'PY'
import json, os, re, sys

node_path, conf_path = sys.argv[1], sys.argv[2]
data = json.load(open(node_path))
address = data["interfaces"][0]["address"]
secondaries = data.get("secondaries", [])

conf = open(conf_path).read().replace("127.0.0.2", address)

if data.get("secondary"):
    stanza = [
        'zone "lab.internal" {',
        "    type secondary;",
        '    file "lab.internal.zone";',
        f'    masters {{ {data["secondary"]}; }};',
        "    allow-transfer { none; };",
        "};",
    ]
else:
    peers = " ".join(f"{peer};" for peer in secondaries) or "none;"
    stanza = [
        'zone "lab.internal" {',
        "    type primary;",
        '    file "lab.internal.zone";',
        f"    allow-transfer {{ {peers} }};",
    ]
    if secondaries:
        stanza.append(f"    also-notify {{ {peers} }};")
    stanza += ["    allow-update { none; };", "};"]

conf = re.sub(
    r"# BEGIN ultus-zone\n.*?# END ultus-zone\n",
    "# BEGIN ultus-zone\n" + "\n".join(stanza) + "\n# END ultus-zone\n",
    conf,
    flags=re.S,
)
open(conf_path, "w").write(conf)

# A secondary takes the zone from its master. A shipped copy carries the same
# serial, so BIND would keep it instead of transferring, and the file is
# removed before the first boot.
if data.get("secondary"):
    for suffix in ("", ".jnl"):
        try:
            os.unlink(f"/var/named/lab.internal.zone{suffix}")
        except FileNotFoundError:
            pass
PY

if [ -z "$address" ]; then
  echo "provision: no node address" >&2
  exit 1
fi
# The node's resolver answers from its own named, whether it owns the zone or
# copies it, so the forwarder is always this node's address.
sed -i "s/^\( *forward-addr: \).*/\1${address}/" /etc/unbound/unbound.conf

if [ -z "$secondary" ]; then
  short=${name%%.*}
  sed -i "s/\bdns-a\b/${short}/g; s/127\.0\.0\.2/${address}/g" /var/named/lab.internal.zone
  named-checkconf -z /etc/named.conf
else
  # A secondary has no local zone file until the transfer, so loading zones
  # here would fail. The health check proves the transferred zone answers.
  named-checkconf /etc/named.conf
fi
unbound-checkconf
