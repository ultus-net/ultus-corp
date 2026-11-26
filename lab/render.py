"""Render the lab TOML spec into libvirt XML and NoCloud seed content.

Standard library only. `load` validates into frozen dataclasses and rejects
anything the renderer would otherwise have to guess.
"""

from __future__ import annotations

import hashlib
import ipaddress
import json
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

__all__ = [
    "Lab",
    "Site",
    "Segment",
    "Scenario",
    "Interface",
    "Node",
    "Spec",
    "load",
    "nodes_for",
    "network_xml",
    "domain_xml",
    "seed_files",
    "interface_mac",
]

TOP_KEYS = {"lab", "site", "scenario", "node"}
LAB_KEYS = {"realm", "domain", "overlay"}
SITE_KEYS = {"id", "prefix", "segment"}
SEGMENT_KEYS = {"name", "cidr"}
SCENARIO_KEYS = {"id", "title", "vm_budget", "ram_budget_mib"}
NODE_KEYS = {
    "scenario",
    "name",
    "site",
    "role",
    "vcpus",
    "ram_mib",
    "disk_gib",
    "interface",
}
IFACE_KEYS = {"segment", "address", "gateway", "nameservers"}


@dataclass(frozen=True)
class Lab:
    realm: str
    domain: str
    overlay: str


@dataclass(frozen=True)
class Segment:
    name: str
    cidr: str


@dataclass(frozen=True)
class Site:
    id: str
    prefix: str
    segments: dict[str, Segment] = field(default_factory=dict)


@dataclass(frozen=True)
class Scenario:
    id: str
    title: str
    vm_budget: int
    ram_budget_mib: int


@dataclass(frozen=True)
class Interface:
    scenario: str
    node: str
    segment: str
    address: str
    gateway: str
    nameservers: list[str]


@dataclass(frozen=True)
class Node:
    scenario: str
    name: str
    site: str
    role: str
    vcpus: int
    ram_mib: int
    disk_gib: int
    interfaces: list[Interface] = field(default_factory=list)


@dataclass(frozen=True)
class Spec:
    lab: Lab
    sites: dict[str, Site]
    scenarios: dict[str, Scenario]
    nodes: list[Node]


def _reject_unknown(table: dict, allowed: set[str], where: str) -> None:
    unknown = set(table) - allowed
    if unknown:
        raise ValueError(f"unknown key(s) in {where}: {', '.join(sorted(unknown))}")


def _require(table: dict, keys: set[str], where: str) -> None:
    missing = keys - set(table)
    if missing:
        raise ValueError(f"missing key(s) in {where}: {', '.join(sorted(missing))}")


def _net(cidr: str, where: str) -> ipaddress.IPv4Network:
    try:
        return ipaddress.IPv4Network(cidr, strict=True)
    except ValueError as exc:
        raise ValueError(f"invalid CIDR in {where}: {cidr!r}") from exc


def interface_mac(scenario: str, node: str, segment: str) -> str:
    """Stable MAC: local bit set, multicast bit clear, six octets."""
    digest = hashlib.sha256(f"{scenario}-{node}-{segment}".encode()).digest()
    first = (digest[0] | 0x02) & 0xFE
    return ":".join(f"{b:02x}" for b in (first, *digest[1:6]))


def load(path: str | Path) -> Spec:
    """Load and validate the spec, raising ValueError on any defect."""
    source = Path(path)
    if not source.is_file():
        raise ValueError(f"spec file not found: {source}")

    doc = tomllib.loads(source.read_text(encoding="utf-8"))
    _reject_unknown(doc, TOP_KEYS, "top level")

    _require(doc, {"lab"}, "top level")
    lab_raw = doc["lab"]
    _reject_unknown(lab_raw, LAB_KEYS, "[lab]")
    _require(lab_raw, LAB_KEYS, "[lab]")
    lab = Lab(
        realm=str(lab_raw["realm"]),
        domain=str(lab_raw["domain"]),
        overlay=str(lab_raw["overlay"]),
    )
    if not lab.realm or not lab.domain:
        raise ValueError("[lab] realm and domain must be non-empty")
    _net(lab.overlay, "[lab] overlay")

    sites: dict[str, Site] = {}
    for index, site_raw in enumerate(doc.get("site", []), start=1):
        where = f"site #{index}"
        _reject_unknown(site_raw, SITE_KEYS, where)
        _require(site_raw, {"id", "prefix"}, where)
        site_id = str(site_raw["id"])
        if site_id in sites:
            raise ValueError(f"duplicate site id: {site_id}")
        prefix = _net(str(site_raw["prefix"]), f"{where} prefix")

        segments: dict[str, Segment] = {}
        for segment_raw in site_raw.get("segment", []):
            seg_where = f"{where} segment"
            _reject_unknown(segment_raw, SEGMENT_KEYS, seg_where)
            _require(segment_raw, SEGMENT_KEYS, seg_where)
            name = str(segment_raw["name"])
            if name in segments:
                raise ValueError(f"duplicate segment {name} in site {site_id}")
            cidr = _net(str(segment_raw["cidr"]), f"site {site_id} segment {name}")
            if not cidr.subnet_of(prefix):
                raise ValueError(
                    f"segment {name} {cidr} is outside site {site_id} prefix {prefix}"
                )
            segments[name] = Segment(name=name, cidr=str(cidr))

        sites[site_id] = Site(id=site_id, prefix=str(prefix), segments=segments)

    scenarios: dict[str, Scenario] = {}
    for index, scenario_raw in enumerate(doc.get("scenario", []), start=1):
        where = f"scenario #{index}"
        _reject_unknown(scenario_raw, SCENARIO_KEYS, where)
        _require(scenario_raw, {"id", "vm_budget", "ram_budget_mib"}, where)
        scenario_id = str(scenario_raw["id"])
        if scenario_id in scenarios:
            raise ValueError(f"duplicate scenario id: {scenario_id}")
        vm_budget = int(scenario_raw["vm_budget"])
        ram_budget = int(scenario_raw["ram_budget_mib"])
        if vm_budget < 1 or ram_budget < 1:
            raise ValueError(f"scenario {scenario_id} has a non-positive budget")
        scenarios[scenario_id] = Scenario(
            id=scenario_id,
            title=str(scenario_raw.get("title", "")),
            vm_budget=vm_budget,
            ram_budget_mib=ram_budget,
        )

    nodes: list[Node] = []
    seen: set[str] = set()
    counts: dict[str, int] = {}
    rams: dict[str, int] = {}

    for index, node_raw in enumerate(doc.get("node", []), start=1):
        where = f"node #{index}"
        _reject_unknown(node_raw, NODE_KEYS, where)
        _require(
            node_raw,
            {"scenario", "name", "site", "role", "vcpus", "ram_mib", "disk_gib"},
            where,
        )

        scenario = str(node_raw["scenario"])
        if scenario not in scenarios:
            raise ValueError(f"{where} references unknown scenario: {scenario}")

        name = str(node_raw["name"])
        if name in seen:
            raise ValueError(f"duplicate node name: {name}")
        seen.add(name)

        site_id = str(node_raw["site"])
        if site_id not in sites:
            raise ValueError(f"{where} references unknown site: {site_id}")
        site = sites[site_id]

        vcpus = int(node_raw["vcpus"])
        ram_mib = int(node_raw["ram_mib"])
        disk_gib = int(node_raw["disk_gib"])
        if min(vcpus, ram_mib, disk_gib) < 1:
            raise ValueError(f"{where} has a non-positive size")

        interfaces: list[Interface] = []
        for iface_index, iface_raw in enumerate(node_raw.get("interface", []), start=1):
            iface_where = f"{where} interface #{iface_index}"
            _reject_unknown(iface_raw, IFACE_KEYS, iface_where)
            _require(iface_raw, {"segment", "address", "gateway"}, iface_where)

            segment_name = str(iface_raw["segment"])
            if segment_name not in site.segments:
                raise ValueError(
                    f"{iface_where} references unknown segment: {segment_name}"
                )
            segment = site.segments[segment_name]

            address = ipaddress.IPv4Address(str(iface_raw["address"]))
            if address not in ipaddress.IPv4Network(segment.cidr):
                raise ValueError(
                    f"{iface_where} address {address} is outside {segment.cidr}"
                )

            gateway = str(iface_raw["gateway"])
            if ipaddress.IPv4Address(gateway) not in ipaddress.IPv4Network(segment.cidr):
                raise ValueError(
                    f"{iface_where} gateway {gateway} is outside {segment.cidr}"
                )

            nameservers = [str(ns) for ns in iface_raw.get("nameservers", [])]
            interfaces.append(
                Interface(
                    scenario=scenario,
                    node=name,
                    segment=segment_name,
                    address=str(address),
                    gateway=gateway,
                    nameservers=nameservers,
                )
            )

        if not interfaces:
            raise ValueError(f"{where} has no interface")

        counts[scenario] = counts.get(scenario, 0) + 1
        rams[scenario] = rams.get(scenario, 0) + ram_mib
        if counts[scenario] > scenarios[scenario].vm_budget:
            raise ValueError(
                f"scenario {scenario} exceeds its VM budget of "
                f"{scenarios[scenario].vm_budget}"
            )
        if rams[scenario] > scenarios[scenario].ram_budget_mib:
            raise ValueError(
                f"scenario {scenario} exceeds its RAM budget of "
                f"{scenarios[scenario].ram_budget_mib} MiB"
            )

        nodes.append(
            Node(
                scenario=scenario,
                name=name,
                site=site_id,
                role=str(node_raw["role"]),
                vcpus=vcpus,
                ram_mib=ram_mib,
                disk_gib=disk_gib,
                interfaces=interfaces,
            )
        )

    return Spec(lab=lab, sites=sites, scenarios=scenarios, nodes=nodes)


def nodes_for(spec: Spec, scenario: str) -> list[Node]:
    if scenario not in spec.scenarios:
        raise ValueError(f"unknown scenario: {scenario}")
    return [node for node in spec.nodes if node.scenario == scenario]


def network_xml(scenario: str, segment: Segment, spec: Spec) -> str:
    """An isolated libvirt network: no forward to the host, no DHCP, no DNS."""
    net = ipaddress.IPv4Network(segment.cidr)
    gateway = next(net.hosts())
    return (
        "<network>\n"
        f"  <name>ultus-{scenario}-{segment.name}</name>\n"
        "  <forward mode='isolated'/>\n"
        "  <dns enable='no'/>\n"
        f"  <ip address='{gateway}' prefix='{net.prefixlen}'/>\n"
        "</network>\n"
    )


def domain_xml(node: Node, spec: Spec) -> str:
    """Domain XML with one isolated network interface per declared segment."""
    domain = f"ultus-{node.scenario}-{node.name}"
    interfaces = "".join(
        "    <interface type='network'>\n"
        f"      <source network='ultus-{node.scenario}-{iface.segment}'/>\n"
        f"      <mac address='{interface_mac(node.scenario, node.name, iface.segment)}'/>\n"
        "      <model type='virtio'/>\n"
        "    </interface>\n"
        for iface in node.interfaces
    )
    return (
        "<domain type='kvm'>\n"
        f"  <name>{domain}</name>\n"
        f"  <memory unit='MiB'>{node.ram_mib}</memory>\n"
        f"  <vcpu placement='static'>{node.vcpus}</vcpu>\n"
        "  <os>\n"
        "    <type arch='x86_64'>hvm</type>\n"
        "    <boot dev='hd'/>\n"
        "  </os>\n"
        "  <devices>\n"
        "    <disk type='file' device='disk'>\n"
        "      <driver name='qemu' type='qcow2'/>\n"
        f"      <source file='run/{node.scenario}/{domain}.qcow2'/>\n"
        "      <target dev='vda' bus='virtio'/>\n"
        "    </disk>\n"
        "    <disk type='file' device='cdrom'>\n"
        "      <driver name='qemu' type='raw'/>\n"
        f"      <source file='run/{node.scenario}/{domain}-seed.iso'/>\n"
        "      <target dev='sda' bus='sata'/>\n"
        "      <readonly/>\n"
        "    </disk>\n"
        f"{interfaces}"
        "    <console type='pty'/>\n"
        "  </devices>\n"
        "</domain>\n"
    )


def _prefix_for(node: Node, spec: Spec, segment_name: str) -> int:
    cidr = spec.sites[node.site].segments[segment_name].cidr
    return ipaddress.IPv4Network(cidr).prefixlen


def seed_files(node: Node, spec: Spec, ssh_key: str | None = None) -> dict[str, str]:
    """NoCloud seed as three strings. JSON is a valid YAML subset."""
    instance_id = f"ultus-{node.scenario}-{node.name}"
    fqdn = f"{node.name}.{spec.lab.domain}"

    meta = f"instance-id: {instance_id}\nlocal-hostname: {fqdn}\n"

    ethernets = {}
    for index, iface in enumerate(node.interfaces):
        prefix = _prefix_for(node, spec, iface.segment)
        ethernets[f"eth{index}"] = {
            "addresses": [f"{iface.address}/{prefix}"],
            "routes": [{"to": "default", "via": iface.gateway}],
            "nameservers": {"addresses": iface.nameservers},
        }
    network = {"version": 2, "ethernets": ethernets}

    node_payload = {
        "node": instance_id,
        "name": node.name,
        "fqdn": fqdn,
        "role": node.role,
        "scenario": node.scenario,
        "interfaces": [
            {
                "segment": iface.segment,
                "address": iface.address,
                "prefix": _prefix_for(node, spec, iface.segment),
                "gateway": iface.gateway,
                "nameservers": iface.nameservers,
            }
            for iface in node.interfaces
        ],
    }
    user_data = "#cloud-config\n" + json.dumps(
        {
            "hostname": node.name,
            "fqdn": fqdn,
            "disable_root": False,
            "ssh_pwauth": False,
            "users": (
                [{"name": "root", "ssh_authorized_keys": [ssh_key]}]
                if ssh_key
                else []
            ),
            "write_files": [
                {
                    "path": "/run/ultus-corp/node.json",
                    "permissions": "0644",
                    "content": json.dumps(node_payload),
                }
            ],
            "runcmd": ["systemctl enable --now ultus-provision.service"],
        },
        indent=2,
    )

    return {
        "meta-data": meta,
        "user-data": user_data,
        "network-config": json.dumps(network, indent=2),
    }


def main(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", default="lab/lab.toml")
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv[1:])

    spec = load(args.spec)
    nodes = nodes_for(spec, args.scenario)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    for node in nodes:
        (out / f"{node.name}.xml").write_text(domain_xml(node, spec), encoding="utf-8")
        seed_dir = out / f"{node.name}-seed"
        seed_dir.mkdir(exist_ok=True)
        for name, content in seed_files(node, spec).items():
            (seed_dir / name).write_text(content, encoding="utf-8")

    site = spec.sites[nodes[0].site] if nodes else None
    if site:
        for segment in site.segments.values():
            path = out / f"{args.scenario}-{segment.name}.network.xml"
            path.write_text(network_xml(args.scenario, segment, spec), encoding="utf-8")

    plan = {
        "scenario": args.scenario,
        "nodes": {node.name: node.interfaces[0].address for node in nodes},
    }
    (out / "plan.json").write_text(json.dumps(plan, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
