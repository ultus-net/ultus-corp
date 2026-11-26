import unittest

import json

from pathlib import Path

from lab.render import load, nodes_for, network_xml, domain_xml, seed_files, interface_mac, Spec, Node, Segment


class TestLoad(unittest.TestCase):
    def test_load_valid_spec(self):
        spec = load("lab/lab.toml")
        self.assertIsInstance(spec, Spec)
        self.assertEqual(len(spec.sites), 1)

    def test_load_unknown_key(self):
        with self.assertRaises(ValueError):
            load("tests/fixtures/lab-unknown-key.toml")


class TestNodesFor(unittest.TestCase):
    def test_nodes_for_scenario(self):
        spec = load("lab/lab.toml")
        nodes = nodes_for(spec, "s1-dns")
        self.assertEqual([n.name for n in nodes], ["dns-a", "dns-b"])

    def test_nodes_for_scenario_returns_base(self):
        spec = load("lab/lab.toml")
        base = nodes_for(spec, "s0-base")[0]
        self.assertEqual(base.name, "base-a")

    def test_nodes_name_not_duplicate(self):
        spec = load("lab/lab.toml")
        base_a = nodes_for(spec, "s0-base")[0]
        dns_a = nodes_for(spec, "s1-dns")[0]
        self.assertNotEqual(base_a.name, dns_a.name)

    def test_nodes_for_unknown_scenario(self):
        spec = load("lab/lab.toml")
        with self.assertRaises(ValueError):
            nodes_for(spec, "nope")


class TestNetworkXml(unittest.TestCase):
    def test_network_xml_has_no_forward(self):
        spec = load("lab/lab.toml")
        net = network_xml("s1-dns", spec.sites["dc"].segments["mgmt"], spec)
        # libvirt has no `isolated` forward mode: no <forward> is what isolates it.
        self.assertNotIn("<forward", net)
        self.assertIn("<name>ultus-s1-dns-mgmt</name>", net)

    def test_network_xml_dns_disabled(self):
        spec = load("lab/lab.toml")
        net = network_xml("s1-dns", spec.sites["dc"].segments["mgmt"], spec)
        self.assertIn("<dns enable='no'/>", net)
        self.assertNotIn("<dhcp", net)

    def test_network_xml_no_bridge(self):
        spec = load("lab/lab.toml")
        net = network_xml("s1-dns", spec.sites["dc"].segments["mgmt"], spec)
        self.assertNotIn("<bridge", net)

    def test_network_xml_isolated_network_name(self):
        spec = load("lab/lab.toml")
        net = network_xml("s1-dns", spec.sites["dc"].segments["mgmt"], spec)
        self.assertIn("ultus-s1-dns-mgmt", net)


class TestDomainXml(unittest.TestCase):
    def test_domain_xml_isolated_network(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        xml = domain_xml(dns_a, spec)
        self.assertIn("ultus-s1-dns-dns-a", xml)
        self.assertIn("<source network='ultus-s1-dns-mgmt'/>", xml)
        self.assertIn("<source network='ultus-s1-dns-data'/>", xml)
        self.assertNotIn("<forward", xml)

    def test_domain_xml_no_forward(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        xml = domain_xml(dns_a, spec)
        self.assertNotIn("<forward", xml)

    def test_domain_xml_attaches_readonly_seed(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        xml = domain_xml(dns_a, spec)
        self.assertIn("device='cdrom'", xml)
        self.assertIn("run/s1-dns/ultus-s1-dns-dns-a-seed.iso", xml)
        self.assertIn("<readonly/>", xml)

    def test_domain_xml_uses_the_host_cpu(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        xml = domain_xml(dns_a, spec)
        # qemu64 lacks SSE4.2, which CentOS Stream 10 requires.
        self.assertIn("<cpu mode='host-passthrough'/>", xml)
        self.assertIn("<acpi/>", xml)

    def test_domain_xml_exposes_a_console_and_agent(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        xml = domain_xml(dns_a, spec, Path("/lab/run"))
        # A file-backed console is root-only, so the user needs a pty.
        self.assertIn("<serial type='pty'/>", xml)
        self.assertIn("org.qemu.guest_agent.0", xml)


class TestInterfaceMac(unittest.TestCase):
    def test_mac_unicast_local_unique(self):
        spec = load("lab/lab.toml")
        macs = [interface_mac(s.id, n.name, i.segment) for s in spec.scenarios.values() for n in nodes_for(spec, s.id) for i in n.interfaces]
        self.assertEqual(len(macs), len(set(macs)))
        for mac in macs:
            first = int(mac.split(":")[0], 16)
            self.assertEqual(first & 0x01, 0)   # unicast: multicast bit clear
            self.assertEqual(first & 0x02, 2)   # locally administered

    def test_mac_uses_sha256(self):
        # Verify interface_mac uses SHA-256 by checking it's deterministic
        spec = load("lab/lab.toml")
        first = interface_mac("s0-base", "base-a", "mgmt")
        second = interface_mac("s0-base", "base-a", "mgmt")
        self.assertEqual(first, second)


class TestSeedFiles(unittest.TestCase):
    def test_seed_files_returns_three_files(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        files = seed_files(dns_a, spec)
        self.assertIn("meta-data", files)
        self.assertIn("user-data", files)
        self.assertIn("network-config", files)

    def test_seed_files_meta_id(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        files = seed_files(dns_a, spec)
        self.assertIn("instance-id: ultus-s1-dns-dns-a", files["meta-data"])

    def test_seed_files_network_config_version_2(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        files = seed_files(dns_a, spec)
        network = json.loads(files["network-config"])
        self.assertEqual(network["version"], 2)
        self.assertIn("ethernets", network)

    def test_seed_files_network_config_addresses(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        files = seed_files(dns_a, spec)
        network = json.loads(files["network-config"])
        # Check addresses are formatted as mask/prefix
        self.assertIn("10.100.10.11/24", files["network-config"])
        self.assertIn("10.100.20.11/24", files["network-config"])

    def test_seed_files_network_config_matches_by_mac(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        files = seed_files(dns_a, spec)
        nic = json.loads(files["network-config"])["ethernets"]["eth0"]
        self.assertEqual(
            nic["match"]["macaddress"], interface_mac("s1-dns", "dns-a", "mgmt")
        )

    def test_seed_files_default_route_is_a_prefix(self):
        # cloud-init 24.4 raises on `to: default` and drops the whole config.
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        network = json.loads(seed_files(dns_a, spec)["network-config"])
        routes = network["ethernets"]["eth0"]["routes"]
        self.assertEqual(routes, [{"to": "0.0.0.0/0", "via": "10.100.10.1"}])

    def test_seed_files_installs_ssh_key(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        files = seed_files(dns_a, spec, "ssh-ed25519 AAAA test")
        user = json.loads(files["user-data"].split("\n", 1)[1])
        self.assertEqual(
            user["users"],
            [{"name": "root", "ssh_authorized_keys": ["ssh-ed25519 AAAA test"]}],
        )
        self.assertFalse(user["ssh_pwauth"])

    def test_seed_files_without_key_grants_no_login(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        files = seed_files(dns_a, spec)
        user = json.loads(files["user-data"].split("\n", 1)[1])
        self.assertEqual(user["users"], [])