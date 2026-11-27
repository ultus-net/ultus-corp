#!/usr/bin/env bash
# The gate that makes the public repo safe to publish: every rendered network is
# isolated, every lab range is disjoint from the host, every scenario stays in
# its budget, and a deliberately leaking fixture fails the same check.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/checks.sh

python3 -c 'import shutil; shutil.rmtree("run/isolation", ignore_errors=True)'
python3 - <<'PY'
import pathlib, sys
sys.path.insert(0, "lab")
import render

out = pathlib.Path("run/isolation")
out.mkdir(parents=True, exist_ok=True)
spec = render.load("lab/lab.toml")
cidrs, budget = [], []
for scenario in spec.scenarios:
    nodes = render.nodes_for(spec, scenario)
    segments = {}
    for node in nodes:
        site = spec.sites[node.site]
        for iface in node.interfaces:
            segments[iface.segment] = site.segments[iface.segment]
    if not segments:
        raise SystemExit(f"{scenario} declares no segment")
    for segment in segments.values():
        (out / f"{scenario}-{segment.name}.xml").write_text(
            render.network_xml(scenario, segment, spec), encoding="utf-8"
        )
        cidrs.append(segment.cidr)
    declared = spec.scenarios[scenario]
    budget.append(
        f"{scenario}\t{len(nodes)}\t{declared.vm_budget}\t"
        f"{sum(n.ram_mib for n in nodes)}\t{declared.ram_budget_mib}"
    )
(out / "lab-cidrs.txt").write_text("\n".join(sorted(set(cidrs))) + "\n", encoding="utf-8")
(out / "budget.tsv").write_text("\n".join(budget) + "\n", encoding="utf-8")
PY

for xml in run/isolation/*.xml; do
  assert_ok "isolated network: ${xml##*/}" check_network_isolated "$xml"
done
assert_ok "the safe fixture is accepted" check_network_isolated tests/fixtures/network-safe.xml
assert_fails "the leaking fixture is rejected" check_network_isolated tests/fixtures/network-leaking.xml

while IFS=$'\t' read -r scenario nodes vm_budget ram ram_budget; do
  assert_ok "$scenario stays within $vm_budget VMs" test "$nodes" -le "$vm_budget"
  assert_ok "$scenario stays within ${ram_budget} MiB" test "$ram" -le "$ram_budget"
done < run/isolation/budget.tsv

assert_ok "the host uplinks are known" lab doctor --host-uplinks
lab doctor --host-uplinks > run/isolation/host-prefixes.txt
assert_ok "the host uplink list is not empty" test -s run/isolation/host-prefixes.txt
assert_ok "every lab range is disjoint from the host" python3 - <<'PY'
import ipaddress, pathlib, sys

lab = [
    ipaddress.ip_network(line.strip())
    for line in pathlib.Path("run/isolation/lab-cidrs.txt").read_text().splitlines()
    if line.strip()
]
host = [
    ipaddress.ip_network(line.strip())
    for line in pathlib.Path("run/isolation/host-prefixes.txt").read_text().splitlines()
    if line.strip()
]
overlaps = [
    f"{a} overlaps {b}"
    for a in lab
    for b in host
    if a.version == b.version and a.overlaps(b)
]
if overlaps:
    print("; ".join(overlaps))
    sys.exit(1)
PY

# The real tree, not only fixtures. A gate that never reads the repository can
# pass while the repository publishes something it should not.
assert_ok "real core pin" check_base_pin manifests/base.txt Containerfile.core
assert_ok "real role pin" check_role_froms_core Containerfile.dns
assert_ok "real manifests" \
  check_manifest_one_per_line manifests/packages-common.txt manifests/packages-dns.txt
assert_ok "real tree secrets" check_no_secret_patterns --tree .
# The tree scan excludes the deliberate fixtures, so prove the path-scoped scan
# still catches them. An exclusion that also anesthetised the check would hide
# the exact leak the fixture exists to represent.
assert_fails "the secret fixture is still caught" \
  check_no_secret_patterns tests/fixtures/leak-key.txt
assert_fails "the media fixture is still caught" check_no_install_media tests/fixtures
assert_ok "no tracked secrets" check_no_tracked_secrets lab-secrets
assert_ok "no installation media" check_no_install_media --tree .
assert_ok "real role records" check_role_records docs/roles

finish
