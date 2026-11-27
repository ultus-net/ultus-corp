"""Render the lab TOML spec into libvirt XML and NoCloud seed content.

Standard library only. `load` validates into frozen dataclasses and rejects
anything the renderer would otherwise have to guess.
"""

from __future__ import annotations

import hashlib
import ipaddress
import json
import re
import sys
import tomllib
import uuid
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# A deployment id is a systemd instance name, so it is a lowercase UUIDv4 and
# nothing else. `finalize.sh` refuses anything that does not match.
DEPLOYMENT_ID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)


def _parse_pool(pool_raw: str, segment_cidr: ipaddress.IPv4Network) -> str:
    """Normalise a Kea range such as '10.200.10.100 - 10.200.10.199'.

    A range must be ordered and stay inside the segment network.
    """
    parts = pool_raw.split("-")
    if len(parts) != 2:
        raise ValueError(f"invalid pool format: {pool_raw!r}")

    try:
        pool_start = ipaddress.IPv4Address(parts[0].strip())
        pool_end = ipaddress.IPv4Address(parts[1].strip())
    except ValueError as exc:
        raise ValueError(f"pool contains invalid addresses: {pool_raw!r}") from exc

    if pool_start > pool_end:
        raise ValueError(f"pool start {pool_start} is after end {pool_end}")
    if pool_start not in segment_cidr or pool_end not in segment_cidr:
        raise ValueError(f"pool range {pool_start}-{pool_end} is outside {segment_cidr}")

    return f"{pool_start} - {pool_end}"


__all__ = [
    "Lab",
    "Dns",
    "Delegate",
    "Site",
    "Segment",
    "Scenario",
    "Interface",
    "Route",
    "Node",
    "Spec",
    "load",
    "nodes_for",
    "primary_of",
    "secondaries_of",
    "zone_text",
    "named_conf_text",
    "unbound_conf_text",
    "managed_files",
    "managed_manifest",
    "new_deployment_id",
    "node_identity",
    "network_xml",
    "domain_xml",
    "seed_files",
    "interface_mac",
    "scenario_segments",
    "kea_conf_text",
    "relay_conf_text",
]

TOP_KEYS = {"lab", "dns", "site", "scenario", "node"}
LAB_KEYS = {"realm", "domain", "overlay"}
DNS_KEYS = {"serial", "ttl", "refresh", "retry", "expire", "minimum", "delegate"}
DELEGATE_KEYS = {"name", "ns", "address"}
SITE_KEYS = {"id", "prefix", "segment"}
SEGMENT_KEYS = {"name", "cidr", "pool"}
SCENARIO_KEYS = {"id", "title", "vm_budget", "ram_budget_mib"}
NODE_KEYS = {
    "scenario",
    "name",
    "site",
    "role",
    "profile",
    "secondary",
    "vcpus",
    "ram_mib",
    "disk_gib",
    "interface",
}
IFACE_KEYS = {"segment", "address", "gateway", "nameservers", "mode", "routes"}
ROUTE_KEYS = {"to", "via"}


@dataclass(frozen=True)
class Lab:
    realm: str
    domain: str
    overlay: str


@dataclass(frozen=True)
class Delegate:
    """A subdomain handed to a node that does not exist yet.

    The glue address is in the spec because the delegation must be provable
    before the identity role is built.
    """

    name: str
    ns: str
    address: str


@dataclass(frozen=True)
class Dns:
    serial: int
    ttl: int
    refresh: int
    retry: int
    expire: int
    minimum: int
    delegates: tuple[Delegate, ...] = ()


@dataclass(frozen=True)
class Segment:
    name: str
    cidr: str
    pool: str | None = None


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
    address: str | None
    gateway: str | None
    nameservers: list[str]
    mode: str
    site: str
    routes: tuple[Route, ...] = ()


@dataclass(frozen=True)
class Route:
    to: str
    via: str


@dataclass(frozen=True)
class Node:
    scenario: str
    name: str
    site: str
    role: str
    profile: str | None
    vcpus: int
    ram_mib: int
    disk_gib: int
    interfaces: list[Interface] = field(default_factory=list)
    secondary: str | None = None


@dataclass(frozen=True)
class Spec:
    lab: Lab
    dns: Dns
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


def _segment_in(sites: dict[str, Site], site_id: str, name: str) -> tuple[str, Segment]:
    """Resolve a segment name to the site that owns it.

    The name is unique across the spec: a second site that defines it is an
    error naming every site, because both would render the same network name.
    """
    matches = [
        (other_id, site.segments[name])
        for other_id, site in sites.items()
        if name in site.segments
    ]
    if not matches:
        raise ValueError(f"segment {name!r} not found for site {site_id!r}")
    if len(matches) > 1:
        found = ", ".join(sorted(other_id for other_id, _ in matches))
        raise ValueError(f"segment {name!r} is defined in multiple sites: {found}")
    return matches[0]


def _segment_for(spec: Spec, site_id: str, name: str) -> tuple[str, Segment]:
    """Resolve a segment name against the whole spec's sites."""
    return _segment_in(spec.sites, site_id, name)


def _served_interface(node: Node, spec: Spec) -> Interface:
    """The relay interface whose segment has a pool.

    The mode is irrelevant: a relay interface is static. Zero or more than one
    matching interface is a ValueError.
    """
    pools = [
        iface
        for iface in node.interfaces
        if spec.sites[iface.site].segments[iface.segment].pool is not None
    ]
    if len(pools) == 0:
        raise ValueError(f"no pool on any interface for {node.name} in {node.scenario}")
    if len(pools) > 1:
        raise ValueError(f"more than one pool interface for {node.name} in {node.scenario}")
    return pools[0]


def _profile_node(node: Node, spec: Spec, profile: str) -> Node:
    """The only node in the scenario with that profile.

    Raises ValueError when not found or not unique.
    """
    nodes = [n for n in nodes_for(spec, node.scenario) if n.profile == profile]
    if not nodes:
        raise ValueError(f"no node with profile {profile} in {node.scenario}")
    if len(nodes) > 1:
        site_ids = sorted(n.site for n in nodes)
        raise ValueError(
            f"multiple nodes with profile {profile} in {node.scenario} "
            f"in sites {', '.join(site_ids)}"
        )
    return nodes[0]


def scenario_segments(spec: Spec, scenario: str) -> list[Segment]:
    """Return each segment once, across every site the scenario uses.

    Two sites in one scenario that provide the same segment name are an error
    because both would render a network with the same libvirt name.
    """
    if scenario not in spec.scenarios:
        raise ValueError(f"unknown scenario: {scenario}")

    segments: dict[str, Segment] = {}
    for node in nodes_for(spec, scenario):
        for iface in node.interfaces:
            _, segment = _segment_for(spec, iface.site, iface.segment)
            segments.setdefault(segment.name, segment)

    return list(segments.values())


def kea_conf_text(node: Node, spec: Spec) -> str:
    """The Kea JSON for a server node.

    Only the DHCP4 configuration is needed; the client is not service-aware.
    """
    relay = _profile_node(node, spec, "relay")
    served = _served_interface(relay, spec)
    segment = spec.sites[served.site].segments[served.segment]

    return json.dumps(
        {
            "Dhcp4": {
                "interfaces-config": {
                    "interfaces": ["*"],
                    "dhcp-socket-type": "udp",
                },
                "control-socket": {
                    "socket-type": "unix",
                    "socket-name": "/var/run/kea/kea4-ctrl-socket",
                },
                # The control socket cannot list a lease without this hook.
                "hooks-libraries": [
                    {"library": "/usr/lib64/kea/hooks/libdhcp_lease_cmds.so"},
                ],
                "lease-database": {
                    "type": "memfile",
                    "name": "/var/lib/kea/kea-leases4.csv",
                    "lfc-interval": 3600,
                },
                "valid-lifetime": 3600,
                "subnet4": [
                    {
                        "id": 1,
                        "subnet": segment.cidr,
                        "pools": [{"pool": segment.pool}],
                        "relay": {"ip-addresses": [served.address]},
                    }
                ],
            }
        },
        indent=2,
    )


def relay_conf_text(node: Node, spec: Spec) -> str:
    """The dnsmasq config for a relay node.

    Emitted as plain text for easy diffing.
    """
    served = _served_interface(node, spec)
    server = _profile_node(node, spec, "server")

    return (
        "# Relay DHCP between the branch segment and the Kea server.\n"
        "port=0\n"
        f"dhcp-relay={served.address},{server.interfaces[0].address}\n"
    )


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

    dns_raw = doc.get("dns", {})
    _reject_unknown(dns_raw, DNS_KEYS, "[dns]")
    if dns_raw:
        _require(dns_raw, {"serial"}, "[dns]")
    delegates: list[Delegate] = []
    for index, delegate_raw in enumerate(dns_raw.get("delegate", []), start=1):
        where = f"[dns] delegate #{index}"
        _reject_unknown(delegate_raw, DELEGATE_KEYS, where)
        _require(delegate_raw, DELEGATE_KEYS, where)
        name = str(delegate_raw["name"])
        ns = str(delegate_raw["ns"])
        if not name or "." in name:
            raise ValueError(f"{where} name must be a single label: {name!r}")
        if not ns.endswith(f".{lab.domain}."):
            raise ValueError(f"{where} ns must end with .{lab.domain}.: {ns!r}")
        delegates.append(
            Delegate(
                name=name,
                ns=ns,
                address=str(ipaddress.IPv4Address(str(delegate_raw["address"]))),
            )
        )
    dns = Dns(
        serial=int(dns_raw.get("serial", 1)),
        ttl=int(dns_raw.get("ttl", 3600)),
        refresh=int(dns_raw.get("refresh", 3600)),
        retry=int(dns_raw.get("retry", 600)),
        expire=int(dns_raw.get("expire", 604800)),
        minimum=int(dns_raw.get("minimum", 300)),
        delegates=tuple(delegates),
    )
    if dns.serial < 1:
        raise ValueError("[dns] serial must be a positive integer")

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
            _require(segment_raw, {"name", "cidr"}, seg_where)
            name = str(segment_raw["name"])
            if name in segments:
                raise ValueError(f"duplicate segment {name} in site {site_id}")
            cidr = _net(str(segment_raw["cidr"]), f"site {site_id} segment {name}")
            if not cidr.subnet_of(prefix):
                raise ValueError(
                    f"segment {name} {cidr} is outside site {site_id} prefix {prefix}"
                )
            pool_raw = segment_raw.get("pool")
            pool = _parse_pool(str(pool_raw), cidr) if pool_raw is not None else None
            segments[name] = Segment(name=name, cidr=str(cidr), pool=pool)

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

        vcpus = int(node_raw["vcpus"])
        ram_mib = int(node_raw["ram_mib"])
        disk_gib = int(node_raw["disk_gib"])
        if min(vcpus, ram_mib, disk_gib) < 1:
            raise ValueError(f"{where} has a non-positive size")

        role = str(node_raw["role"])
        if role not in ("dns", "dhcp", "client"):
            raise ValueError(f"{where} role {role!r} is not dns, dhcp or client")

        profile_raw = node_raw.get("profile")
        profile = str(profile_raw) if profile_raw is not None else None
        if role == "dhcp":
            if profile is None:
                raise ValueError(f"{where} profile is required for role {role!r}")
        elif profile is not None:
            raise ValueError(f"{where} profile is rejected for role {role!r}")

        interfaces: list[Interface] = []
        for iface_index, iface_raw in enumerate(node_raw.get("interface", []), start=1):
            iface_where = f"{where} interface #{iface_index}"
            _reject_unknown(iface_raw, IFACE_KEYS, iface_where)

            segment_name = str(iface_raw["segment"])
            segment_site, segment = _segment_in(sites, site_id, segment_name)
            segment_cidr = ipaddress.IPv4Network(segment.cidr)

            mode = str(iface_raw.get("mode", "static"))
            if mode not in ("static", "dhcp"):
                raise ValueError(f"{iface_where} mode {mode!r} must be 'static' or 'dhcp'")
            if iface_index == 1 and mode != "static":
                raise ValueError(f"{where} requires a static first interface")
            if mode == "dhcp" and role != "client":
                raise ValueError(f"{iface_where} dhcp mode is client-only")

            if mode == "dhcp":
                if "address" in iface_raw:
                    raise ValueError(f"{iface_where} dhcp mode cannot declare an address")
                if "gateway" in iface_raw:
                    raise ValueError(f"{iface_where} dhcp mode cannot declare a gateway")
                if "nameservers" in iface_raw:
                    raise ValueError(f"{iface_where} dhcp mode cannot declare nameservers")
                if "routes" in iface_raw:
                    raise ValueError(f"{iface_where} dhcp mode cannot declare routes")

                address = None
                gateway = None
                nameservers = []
                routes = ()
            else:
                _require(iface_raw, {"address"}, iface_where)

                address = ipaddress.IPv4Address(str(iface_raw["address"]))
                if address not in segment_cidr:
                    raise ValueError(
                        f"{iface_where} address {address} is outside {segment_cidr}"
                    )

                gateway_raw = iface_raw.get("gateway")
                gateway = None
                if gateway_raw is not None:
                    gateway = str(ipaddress.IPv4Address(str(gateway_raw)))
                    if ipaddress.IPv4Address(gateway) not in segment_cidr:
                        raise ValueError(
                            f"{iface_where} gateway {gateway} is outside {segment_cidr}"
                        )

                nameservers = [str(ns) for ns in iface_raw.get("nameservers", [])]

                routes = []
                for route_index, route_raw in enumerate(iface_raw.get("routes", []), start=1):
                    route_where = f"{iface_where} routes #{route_index}"
                    _reject_unknown(route_raw, ROUTE_KEYS, route_where)
                    _require(route_raw, ROUTE_KEYS, route_where)

                    to_str = str(route_raw["to"])
                    _net(to_str, route_where)

                    via = str(ipaddress.IPv4Address(str(route_raw["via"])))
                    if ipaddress.IPv4Address(via) not in segment_cidr:
                        raise ValueError(
                            f"{route_where} via {via} is outside {segment_cidr}"
                        )

                    routes.append(Route(to=to_str, via=via))
                routes = tuple(routes)

            interfaces.append(
                Interface(
                    scenario=scenario,
                    node=name,
                    segment=segment_name,
                    address=str(address) if address else None,
                    gateway=gateway,
                    nameservers=nameservers,
                    mode=mode,
                    site=segment_site,
                    routes=routes,
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
                profile=profile,
                vcpus=vcpus,
                ram_mib=ram_mib,
                disk_gib=disk_gib,
                interfaces=interfaces,
                secondary=(
                    str(node_raw["secondary"]) if "secondary" in node_raw else None
                ),
            )
        )

    for scenario_id in scenarios:
        dhcp_nodes = [
            n for n in nodes if n.scenario == scenario_id and n.role == "dhcp"
        ]
        servers = [n for n in dhcp_nodes if n.profile == "server"]
        relays = [n for n in dhcp_nodes if n.profile == "relay"]
        if len(servers) > 1:
            raise ValueError(
                f"scenario {scenario_id} has more than one dhcp server: "
                f"{', '.join(n.name for n in servers)}"
            )
        if len(relays) > 1:
            raise ValueError(
                f"scenario {scenario_id} has more than one dhcp relay: "
                f"{', '.join(n.name for n in relays)}"
            )
        if relays and not servers:
            raise ValueError(f"scenario {scenario_id} has a dhcp relay but no server")

    by_name = {node.name: node for node in nodes}

    for site_id, site in sites.items():
        for segment_name, segment in site.segments.items():
            if segment.pool is None:
                continue
            pool_start_raw, pool_end_raw = segment.pool.split(" - ")
            pool_start = ipaddress.IPv4Address(pool_start_raw)
            pool_end = ipaddress.IPv4Address(pool_end_raw)

            for node in nodes:
                for iface in node.interfaces:
                    if iface.site != site_id or iface.segment != segment_name:
                        continue
                    if iface.mode != "static" or iface.address is None:
                        continue
                    address = ipaddress.IPv4Address(iface.address)
                    if pool_start <= address <= pool_end:
                        raise ValueError(
                            f"pool {segment.pool!r} in segment {segment_name} "
                            f"contains static address {iface.address!r} "
                            f"from node {node.name}"
                        )

    for node in nodes:
        if node.secondary is None:
            continue
        primary = by_name.get(node.secondary)
        if primary is None:
            raise ValueError(
                f"node {node.name} has an unknown secondary: {node.secondary}"
            )
        if primary.scenario != node.scenario:
            raise ValueError(
                f"node {node.name} names a secondary in scenario "
                f"{primary.scenario}, not {node.scenario}"
            )
        if primary.secondary is not None:
            raise ValueError(
                f"node {node.name} names {primary.name}, which is itself a secondary"
            )

    return Spec(lab=lab, dns=dns, sites=sites, scenarios=scenarios, nodes=nodes)


def primary_of(node: Node, spec: Spec) -> Node | None:
    """The node this one copies its zone from, or None when it owns the zone."""
    if node.secondary is None:
        return None
    return next(n for n in spec.nodes if n.name == node.secondary)


def secondaries_of(node: Node, spec: Spec) -> list[Node]:
    """The nodes that copy this one's zone."""
    return [n for n in spec.nodes if n.secondary == node.name]


def nodes_for(spec: Spec, scenario: str) -> list[Node]:
    if scenario not in spec.scenarios:
        raise ValueError(f"unknown scenario: {scenario}")
    return [node for node in spec.nodes if node.scenario == scenario]


def network_xml(scenario: str, segment: Segment, spec: Spec) -> str:
    """An isolated libvirt network: no `<forward>`, so no uplink, DHCP or DNS."""
    net = ipaddress.IPv4Network(segment.cidr)
    gateway = next(net.hosts())
    return (
        "<network>\n"
        f"  <name>ultus-{scenario}-{segment.name}</name>\n"
        "  <dns enable='no'/>\n"
        f"  <ip address='{gateway}' prefix='{net.prefixlen}'/>\n"
        "</network>\n"
    )


def domain_xml(node: Node, spec: Spec, run_dir: Path | None = None) -> str:
    """Domain XML with one isolated network interface per declared segment.

    Paths are absolute because the system-mode daemon does not share the
    caller's working directory.
    """
    base = Path(run_dir) if run_dir else ROOT / "run"
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
        "  <features>\n"
        "    <acpi/>\n"
        "    <apic/>\n"
        "  </features>\n"
        "  <cpu mode='host-passthrough'/>\n"
        "  <devices>\n"
        "    <disk type='file' device='disk'>\n"
        "      <driver name='qemu' type='qcow2'/>\n"
        f"      <source file='{base}/{node.scenario}/{domain}.qcow2'/>\n"
        "      <target dev='vda' bus='virtio'/>\n"
        "    </disk>\n"
        "    <disk type='file' device='cdrom'>\n"
        "      <driver name='qemu' type='raw'/>\n"
        f"      <source file='{base}/{node.scenario}/{domain}-seed.iso'/>\n"
        "      <target dev='sda' bus='sata'/>\n"
        "      <readonly/>\n"
        "    </disk>\n"
        f"{interfaces}"
        "    <serial type='pty'/>\n"
        "    <console type='pty'/>\n"
        "    <channel type='unix'>\n"
        "      <target type='virtio' name='org.qemu.guest_agent.0'/>\n"
        "    </channel>\n"
        "  </devices>\n"
        "</domain>\n"
    )


def _prefix_for(iface: Interface, spec: Spec) -> int:
    cidr = spec.sites[iface.site].segments[iface.segment].cidr
    return ipaddress.IPv4Network(cidr).prefixlen


def _fqdn(name: str, spec: Spec) -> str:
    return f"{name}.{spec.lab.domain}"


def zone_text(node: Node, spec: Spec) -> str:
    """The primary's zone as BIND reads it.

    Every record comes from the spec: the node addresses and the delegation
    glue. No image ships this file, so no run's address is baked into a build.
    """
    owner = primary_of(node, spec) or node
    dns = spec.dns
    lines = [
        f"$TTL {dns.ttl}",
        f"@   IN  SOA {_fqdn(owner.name, spec)}. hostmaster.{spec.lab.domain}. (",
        f"        {dns.serial} ; serial",
        f"        {dns.refresh} ; refresh",
        f"        {dns.retry} ; retry",
        f"        {dns.expire} ; expire",
        f"        {dns.minimum} ) ; minimum",
        f"@       IN  NS  {_fqdn(owner.name, spec)}.",
    ]
    for peer in nodes_for(spec, node.scenario):
        lines.append(f"{peer.name}   IN  A   {peer.interfaces[0].address}")
    for delegate in dns.delegates:
        lines += [
            "",
            f"; {delegate.name} is delegated before its node exists, so the",
            "; delegation is proven independently of that role's work.",
            f"{delegate.name}   IN  NS  {delegate.ns}",
            f"{delegate.name}   IN  A   {delegate.address}",
        ]
    return "\n".join(lines) + "\n"


def named_conf_text(node: Node, spec: Spec) -> str:
    """The node's named.conf, final, with no placeholder left to substitute."""
    own = node.interfaces[0].address
    options = [
        "options {",
        '    directory "/var/named";',
        f"    listen-on port 53 {{ {own}; 127.0.0.1; }};",
        "    listen-on-v6 { none; };",
        "    recursion no;",
        "    allow-query { any; };",
        "    allow-transfer { none; };",
        "    dnssec-validation no;",
        "};",
        "",
    ]
    primary = primary_of(node, spec)
    if primary is not None:
        stanza = [
            f'zone "{spec.lab.domain}" {{',
            "    type secondary;",
            '    file "lab.internal.zone";',
            f"    masters {{ {primary.interfaces[0].address}; }};",
            "    allow-transfer { none; };",
            "};",
        ]
    else:
        peers = [p.interfaces[0].address for p in secondaries_of(node, spec)]
        transfer = " ".join(f"{peer};" for peer in peers) or "none;"
        stanza = [
            f'zone "{spec.lab.domain}" {{',
            "    type primary;",
            '    file "lab.internal.zone";',
            f"    allow-transfer {{ {transfer} }};",
        ]
        if peers:
            stanza.append(f"    also-notify {{ {transfer} }};")
        stanza += ["    allow-update { none; };", "};"]
    return "\n".join(options + stanza) + "\n"


def unbound_conf_text(node: Node, spec: Spec) -> str:
    """The node's resolver. It forwards the zone to its own named."""
    own = node.interfaces[0].address
    return (
        "server:\n"
        "    # The package is built with /etc/unbound as its default chroot, and the unit\n"
        "    # is Type=notify. Inside that chroot the daemon cannot see\n"
        "    # /run/systemd/notify, so it exits at startup with a fatal sd_notify error\n"
        "    # while unbound-checkconf still calls the file valid.\n"
        '    chroot: ""\n'
        "    interface: 127.0.0.1\n"
        "    port: 53\n"
        "    do-not-query-localhost: no\n"
        "    access-control: 127.0.0.0/8 allow\n"
        "    access-control: 10.0.0.0/8 allow\n"
        "    verbosity: 1\n"
        "\n"
        "forward-zone:\n"
        f'    name: "{spec.lab.domain}"\n'
        f"    forward-addr: {own}\n"
    )


def managed_files(node: Node, spec: Spec) -> dict[str, str]:
    """Every configuration file the deployment owns, with its final content.

    A secondary gets no zone: a shipped copy would carry the primary's serial,
    so BIND would keep it instead of transferring.
    """
    if node.role == "dhcp":
        if node.profile == "server":
            return {"/etc/kea/kea-dhcp4.conf": kea_conf_text(node, spec)}
        if node.profile == "relay":
            return {
                "/etc/ultus-corp/dhcp-relay.conf": relay_conf_text(node, spec)
            }
        return {}
    if node.role != "dns":
        return {}
    files = {
        "/etc/named.conf": named_conf_text(node, spec),
        "/etc/unbound/unbound.conf": unbound_conf_text(node, spec),
    }
    if primary_of(node, spec) is None:
        files["/var/named/lab.internal.zone"] = zone_text(node, spec)
    return dict(sorted(files.items()))


def managed_manifest(node: Node, spec: Spec) -> str:
    """The expected post-deploy checksums, taken from the rendered bytes."""
    return "".join(
        f"{hashlib.sha256(content.encode()).hexdigest()}  {path}\n"
        for path, content in managed_files(node, spec).items()
    )


def new_deployment_id() -> str:
    """A fresh lowercase UUIDv4, always a valid systemd instance name."""
    return str(uuid.uuid4())


def node_identity(node: Node, spec: Spec) -> dict:
    """The identity facts the applier reads at /run/ultus-corp/node.json.

    It carries no per-site value the guest could render: the configuration it
    needs is already final in the seed.
    """
    dhcp_interfaces = [
        {
            "segment": iface.segment,
            "cidr": spec.sites[iface.site].segments[iface.segment].cidr,
        }
        for iface in node.interfaces
        if iface.mode == "dhcp"
    ]
    return {
        "name": node.name,
        "fqdn": _fqdn(node.name, spec),
        "role": node.role,
        "profile": node.profile,
        "scenario": node.scenario,
        "primary": primary_of(node, spec) is None,
        "dhcp_interfaces": dhcp_interfaces,
    }


def seed_files(
    node: Node,
    spec: Spec,
    ssh_key: str | None = None,
    deployment_id: str | None = None,
) -> dict[str, str]:
    """NoCloud seed as three strings. JSON is a valid YAML subset."""
    instance_id = f"ultus-{node.scenario}-{node.name}"
    fqdn = _fqdn(node.name, spec)
    deployment = deployment_id or new_deployment_id()
    if not DEPLOYMENT_ID.match(deployment):
        raise ValueError(f"deployment id is not a lowercase UUIDv4: {deployment}")

    # cloud-init ignores unknown meta-data keys, and the systemd instance must
    # carry the same value, so the id is in both places and finalize checks them.
    meta = (
        f"instance-id: {instance_id}\n"
        f"local-hostname: {fqdn}\n"
        f"deployment_id: {deployment}\n"
    )

    ethernets = {}
    for index, iface in enumerate(node.interfaces):
        # Predictable network names differ per bus and host, so match the
        # deterministic MAC this renderer assigns instead of a device name.
        match = {"macaddress": interface_mac(node.scenario, node.name, iface.segment)}
        if iface.mode == "dhcp":
            ethernets[f"eth{index}"] = {"match": match, "dhcp4": True}
            continue

        prefix = _prefix_for(iface, spec)
        entry = {
            "match": match,
            "addresses": [f"{iface.address}/{prefix}"],
        }
        # cloud-init 24.4 rejects `to: default` and then drops the whole
        # config, so the default route is spelled as a prefix.
        routes = []
        if iface.gateway is not None:
            routes.append({"to": "0.0.0.0/0", "via": iface.gateway})
        routes += [{"to": route.to, "via": route.via} for route in iface.routes]
        if routes:
            entry["routes"] = routes
        entry["nameservers"] = {"addresses": iface.nameservers}
        ethernets[f"eth{index}"] = entry
    network = {"version": 2, "ethernets": ethernets}

    write_files = [
        {
            "path": path,
            "owner": "root:named" if path.endswith(".zone") else "root:root",
            "permissions": "0640" if path.endswith(".zone") else "0644",
            "content": content,
        }
        for path, content in managed_files(node, spec).items()
    ]
    write_files.append(
        {
            "path": "/run/ultus-corp/node.json",
            "owner": "root:root",
            "permissions": "0644",
            "content": json.dumps(node_identity(node, spec), indent=2),
        }
    )
    write_files.append(
        {
            "path": "/run/ultus-corp/deployment-id",
            "owner": "root:root",
            "permissions": "0644",
            "content": deployment + "\n",
        }
    )

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
            "write_files": write_files,
            # The ready target is ordered after cloud-final, so enabling the
            # instance here is enough: the target pulls it in once cloud-final
            # finishes, and its condition skips it on every later boot.
            # One command, so a failed role install never reaches the finalize
            # enable: a deployment that did not install must not be recorded.
            # The ready target is started without blocking, because it is
            # ordered after cloud-final and this command runs inside it.
            "runcmd": [
                "set -e; "
                "systemctl start ultus-role-install.target; "
                f"systemctl enable ultus-deploy-finalize@{deployment}.service; "
                "systemctl --no-block start ultus-deploy-ready.target"
            ],
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
        (out / f"{node.name}.managed-files.sha256").write_text(
            managed_manifest(node, spec), encoding="utf-8"
        )
        seed_dir = out / f"{node.name}-seed"
        seed_dir.mkdir(exist_ok=True)
        for name, content in seed_files(node, spec).items():
            (seed_dir / name).write_text(content, encoding="utf-8")

    for segment in scenario_segments(spec, args.scenario):
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
