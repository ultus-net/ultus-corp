# client role

The client is a guest that asks the branch segment for an address and proves it
got one. It adds no package to the core and applies no configuration of its own.

## Linux mechanism

- `NetworkManager` owns every connection. The seed delivers a `network-config`
  v2 document, and cloud-init hands it to NetworkManager, so the image carries
  no connection profile and no address.
- cloud-init matches each NIC by the deterministic MAC the renderer assigns, not
  by a device name, because predictable names differ per bus and host.
- The management NIC stays static, with its address, default route and
  nameservers. Only an interface declared `mode = "dhcp"` asks for a lease, and
  the renderer writes `dhcp4: true` for it.
- The image ships no applier. There is no `/usr/libexec/ultus-corp/provision.sh`,
  and the build hook fails if one appears, because the client has nothing to
  apply.
- `50-client-health.sh` sits in `/etc/greenboot/check/required.d`. It sources
  `deployed.sh` and calls `deployment_gate`, so an unprovisioned first boot is
  not judged. On a deployed host it reads the CIDRs from `dhcp_interfaces` in
  `/run/ultus-corp/node.json`, compares them with `ip -4 -j addr show` through
  Python `ipaddress`, and requires at least one address on one of those
  networks. An identity that names no DHCP interface fails at once, because
  waiting cannot add the key. Otherwise it retries for `ULTUS_HEALTH_TRIES`
  seconds, 120 by default, because the relay and Kea may still be deploying. A
  failing required check keeps `boot-complete.target` unreached, so greenboot
  rolls the host back.

## Windows concept

The Windows concept is a DHCP-enabled workstation NIC plus the DHCP Client
service. The renderer's `dhcp4: true` is the NIC's "Obtain an IP address
automatically" setting, and NetworkManager is the DHCP Client service.

## Where it breaks

- NetworkManager owns the connection, not a per-interface Windows dialog. There
  is no separate adapter property page to read; the state lives in the
  connection NetworkManager created from cloud-init's document.
- cloud-init matches the NIC by the renderer's deterministic MAC. A Windows
  workstation is configured on the adapter itself, so nothing there depends on
  the hypervisor handing out a stable address.
- The management NIC stays static while only the branch NIC asks for DHCP. Both
  sit in one image, and the difference is the interface's mode in the spec.
- The image carries no configuration at all. Nothing in it names a segment, a
  pool or a server, so the same image is a client on any branch.

## Proof

```proof
test -x /etc/greenboot/check/required.d/50-client-health.sh && rpm -q NetworkManager && ! test -e /usr/libexec/ultus-corp/provision.sh
```

Scenario proof: `tests/scenarios/s2-dhcp.sh` reboots this client and requires
the same lease, then stops the relay and requires no lease.
