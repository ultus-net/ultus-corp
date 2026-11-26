#!/usr/bin/env bash
set -euo pipefail

node=/run/ultus-corp/node.json
[ -s "$node" ] || { echo "provision: $node is missing" >&2; exit 1; }

read -r name address forward < <(python3 - "$node" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(
    data["name"],
    data["interfaces"][0]["address"],
    data.get("secondary") or data["interfaces"][0]["address"],
)
PY
)

python3 - "$node" /etc/named.conf <<'PY'
import json, re, sys
node_path, conf_path = sys.argv[1], sys.argv[2]
data = json.load(open(node_path))
address = data["interfaces"][0]["address"]
conf = open(conf_path).read().replace("127.0.0.2", address)
if data.get("secondary"):
    zone = (
        'zone "lab.internal" {\n'
        "    type secondary;\n"
        '    file "lab.internal.zone";\n'
        f'    masters {{ {data["secondary"]}; }};\n'
        "    allow-transfer { none; };\n"
        "};\n"
    )
    conf = re.sub(
        r"# BEGIN ultus-zone\n.*?# END ultus-zone\n",
        "# BEGIN ultus-zone\n" + zone + "# END ultus-zone\n",
        conf,
        flags=re.S,
    )
open(conf_path, "w").write(conf)
PY

if [ -z "${forward}" ]; then
  echo "provision: no forwarder address" >&2
  exit 1
fi
sed -i "s/^\( *forward-addr: \).*/\1${forward}/" /etc/unbound/unbound.conf

short=${name%%.*}
sed -i "s/dns-a\./${short}./g; s/127\.0\.0\.2/${address}/g" /var/named/lab.internal.zone

named-checkconf -z /etc/named.conf
unbound-checkconf
