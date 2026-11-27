import unittest

import json

from pathlib import Path

from lab.render import (
    load,
    nodes_for,
    network_xml,
    domain_xml,
    seed_files,
    interface_mac,
    zone_text,
    named_conf_text,
    unbound_conf_text,
    managed_files,
    managed_manifest,
    new_deployment_id,
    node_identity,
    primary_of,
    secondaries_of,
    Spec,
    Node,
    Segment,
)


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


class TestDnsRendering(unittest.TestCase):
    def primary(self):
        spec = load("lab/lab.toml")
        return spec, nodes_for(spec, "s1-dns")[0]

    def secondary(self):
        spec = load("lab/lab.toml")
        return spec, nodes_for(spec, "s1-dns")[1]

    def test_zone_lists_every_scenario_node(self):
        spec, dns_a = self.primary()
        zone = zone_text(dns_a, spec)
        self.assertIn("dns-a   IN  A   10.100.10.11", zone)
        self.assertIn("dns-b   IN  A   10.100.10.12", zone)

    def test_zone_soa_names_the_primary(self):
        spec, dns_a = self.primary()
        zone = zone_text(dns_a, spec)
        self.assertIn("SOA dns-a.lab.internal. hostmaster.lab.internal.", zone)
        self.assertIn("@       IN  NS  dns-a.lab.internal.", zone)
        self.assertIn("$TTL 3600", zone)

    def test_zone_carries_the_delegation_glue(self):
        spec, dns_a = self.primary()
        zone = zone_text(dns_a, spec)
        self.assertIn("ipa   IN  NS  ipa.lab.internal.", zone)
        self.assertIn("ipa   IN  A   10.100.10.53", zone)

    def test_primary_conf_transfers_and_notifies(self):
        spec, dns_a = self.primary()
        conf = named_conf_text(dns_a, spec)
        self.assertIn("type primary;", conf)
        self.assertIn("allow-transfer { 10.100.10.12; }", conf)
        self.assertIn("also-notify { 10.100.10.12; }", conf)
        self.assertIn("listen-on port 53 { 10.100.10.11; 127.0.0.1; }", conf)

    def test_primary_conf_is_final(self):
        spec, dns_a = self.primary()
        # A placeholder would be a value the guest still had to substitute.
        self.assertNotIn("127.0.0.2", named_conf_text(dns_a, spec))

    def test_secondary_conf_names_its_master(self):
        spec, dns_b = self.secondary()
        conf = named_conf_text(dns_b, spec)
        self.assertIn("type secondary;", conf)
        self.assertIn("masters { 10.100.10.11; }", conf)

    def test_secondary_gets_no_zone(self):
        spec, dns_b = self.secondary()
        self.assertNotIn("/var/named/lab.internal.zone", managed_files(dns_b, spec))

    def test_secondary_deletes_a_stale_zone(self):
        # A shipped or leftover copy would carry the primary's serial.
        spec, dns_b = self.secondary()
        files = managed_files(dns_b, spec)
        self.assertEqual(
            sorted(files), ["/etc/named.conf", "/etc/unbound/unbound.conf"]
        )

    def test_resolver_forwards_to_its_own_named(self):
        spec, dns_a = self.primary()
        spec_b, dns_b = self.secondary()
        self.assertIn("forward-addr: 10.100.10.11", unbound_conf_text(dns_a, spec))
        self.assertIn("forward-addr: 10.100.10.12", unbound_conf_text(dns_b, spec_b))
        self.assertIn('chroot: ""', unbound_conf_text(dns_a, spec))

    def test_manifest_hashes_the_rendered_bytes(self):
        import hashlib

        spec, dns_a = self.primary()
        manifest = managed_manifest(dns_a, spec)
        lines = manifest.splitlines()
        self.assertEqual(len(lines), 3)
        for line in lines:
            digest, path = line.split("  ", 1)
            self.assertEqual(
                digest, hashlib.sha256(managed_files(dns_a, spec)[path].encode()).hexdigest()
            )
        self.assertEqual([line.split("  ", 1)[1] for line in lines], sorted(
            ["/etc/named.conf", "/etc/unbound/unbound.conf", "/var/named/lab.internal.zone"]
        ))

    def test_seed_carries_the_final_configuration(self):
        spec, dns_a = self.primary()
        user = json.loads(seed_files(dns_a, spec)["user-data"].split("\n", 1)[1])
        paths = [item["path"] for item in user["write_files"]]
        self.assertIn("/etc/named.conf", paths)
        self.assertIn("/run/ultus-corp/node.json", paths)
        zone = next(i for i in user["write_files"] if i["path"].endswith(".zone"))
        self.assertEqual(zone["owner"], "root:named")
        self.assertEqual(zone["permissions"], "0640")

    def test_seed_identity_matches_the_applier_contract(self):
        # provision.sh reads one field from this file, so the seed must carry
        # the same identity the renderer exposes, not a second derivation.
        spec, dns_a = self.primary()
        user = json.loads(seed_files(dns_a, spec)["user-data"].split("\n", 1)[1])
        identity = next(
            i for i in user["write_files"] if i["path"] == "/run/ultus-corp/node.json"
        )
        self.assertEqual(json.loads(identity["content"]), node_identity(dns_a, spec))
        self.assertTrue(json.loads(identity["content"])["primary"])

    def test_secondary_seed_says_it_is_not_primary(self):
        spec, dns_b = self.secondary()
        user = json.loads(seed_files(dns_b, spec)["user-data"].split("\n", 1)[1])
        identity = next(
            i for i in user["write_files"] if i["path"] == "/run/ultus-corp/node.json"
        )
        self.assertFalse(json.loads(identity["content"])["primary"])
        self.assertNotIn(
            "/var/named/lab.internal.zone", [i["path"] for i in user["write_files"]]
        )

    def test_identity_marks_a_secondary(self):
        spec, dns_b = self.secondary()
        self.assertFalse(node_identity(dns_b, spec)["primary"])
        self.assertEqual(node_identity(dns_b, spec)["role"], "dns")

    def test_identity_is_not_a_managed_file(self):
        # The identity tells the applier what to do. Gate 10 hashes what the
        # deployment configures, and the identity is neither.
        spec, dns_a = self.primary()
        self.assertNotIn("/run/ultus-corp/node.json", managed_files(dns_a, spec))

    def test_seed_carries_the_deployment_id(self):
        spec, dns_a = self.primary()
        deployment = new_deployment_id()
        seed = seed_files(dns_a, spec, deployment_id=deployment)
        self.assertIn(f"deployment_id: {deployment}", seed["meta-data"])
        user = json.loads(seed["user-data"].split("\n", 1)[1])
        idfile = next(
            i
            for i in user["write_files"]
            if i["path"] == "/run/ultus-corp/deployment-id"
        )
        self.assertEqual(idfile["content"].strip(), deployment)
        # One command, so a failed role install cannot reach the finalize
        # enable. The target is started after the instance is enabled, so it
        # pulls that instance in.
        runcmd = user["runcmd"]
        self.assertEqual(len(runcmd), 1, runcmd)
        self.assertIn("systemctl start ultus-role-install.target", runcmd[0])
        self.assertIn(
            f"systemctl enable ultus-deploy-finalize@{deployment}.service", runcmd[0]
        )
        self.assertIn(
            "systemctl --no-block start ultus-deploy-ready.target", runcmd[0]
        )
        self.assertLess(
            runcmd[0].index("ultus-role-install.target"),
            runcmd[0].index("ultus-deploy-finalize@"),
        )

    def test_deployment_id_is_a_lowercase_uuidv4(self):
        import re

        pattern = r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        first, second = new_deployment_id(), new_deployment_id()
        self.assertRegex(first, pattern)
        self.assertNotEqual(first, second)

    def test_a_bad_deployment_id_is_rejected(self):
        spec, dns_a = self.primary()
        for bad in ("not-a-uuid", "../../etc/passwd", "ABCDEF00-0000-4000-8000-000000000000"):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    seed_files(dns_a, spec, deployment_id=bad)

    def test_unknown_dns_key_rejected(self):
        from pathlib import Path as P
        import tempfile

        source = P("lab/lab.toml").read_text()
        with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as handle:
            handle.write(source.replace('serial = 2026112701', 'serial = 2026112701\nbogus = 1'))
            path = handle.name
        with self.assertRaises(ValueError):
            load(path)
        P(path).unlink()


class TestTopology(unittest.TestCase):
    def test_primary_lists_its_secondaries(self):
        spec = load("lab/lab.toml")
        dns_a = nodes_for(spec, "s1-dns")[0]
        self.assertEqual([n.name for n in secondaries_of(dns_a, spec)], ["dns-b"])

    def test_secondary_names_the_primary(self):
        spec = load("lab/lab.toml")
        dns_b = nodes_for(spec, "s1-dns")[1]
        self.assertEqual(primary_of(dns_b, spec).name, "dns-a")

    def test_secondary_must_exist(self):
        with self.assertRaises(ValueError):
            load("tests/fixtures/lab-unknown-secondary.toml")

    def test_a_secondary_cannot_copy_a_secondary(self):
        with self.assertRaises(ValueError):
            load("tests/fixtures/lab-secondary-of-secondary.toml")