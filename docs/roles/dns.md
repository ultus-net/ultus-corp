# dns role

BIND 9 is the authoritative server for `lab.internal`, reachable on the node's
first interface. Unbound is the node's own recursive resolver on
`127.0.0.1:53`, so a node can answer its own lookups before any other host
exists.

## Linux mechanism

- `named` serves `lab.internal` from `/var/named/lab.internal.zone`, with
  recursion off. A primary accepts transfers from the secondaries named in the
  spec and notifies them. A secondary copies the zone from its primary with
  `type secondary` and `masters`, and serves no transfers itself.
- `unbound` listens on `127.0.0.1:53` and forwards `lab.internal` to this node's
  own address, whether the node owns the zone or copies it. A secondary that
  forwarded to its primary would fail its own health check during a failover.
- `ultus-provision.service` runs before `named` and rewrites both files from
  `/run/ultus-corp/node.json`: the authoritative listen address, the unbound
  forwarder, the zone stanza for this node's role, and, on a primary, the zone's
  owner name and address.
- `ultus-dns-ready.service` runs `named-checkconf` on the file, which checks
  syntax only. A secondary has no zone file until its transfer, so loading the
  zones at boot would fail every secondary.
- `50-dns-health.sh` sits in `/etc/greenboot/check/required.d`, queries
  `127.0.0.1` for the zone's `SOA` and requires `status: NOERROR`. It retries for
  thirty seconds, because a secondary has no zone until its transfer completes.

## Windows concept

The pair maps to an AD-integrated DNS server plus a forwarder, or to DNS Server
with a conditional forwarder. The zone is the AD domain zone, the forwarder is
the recursive resolver, and the failover pair is a primary and secondary zone.
The generated config is the Group Policy equivalent.

## Where it breaks

- BIND and Unbound cannot both bind `127.0.0.1:53`. The image therefore gives
  BIND `127.0.0.2` at build time and moves it to the node address at boot.
- A zone file written at build time cannot carry a per-run address. The image
  ships a placeholder record for `dns-a` on `127.0.0.2`, and provisioning
  rewrites the owner name and the address to the node's own. The rewrite is
  idempotent.
- A secondary must not keep the shipped zone file. The copy carries the master's
  serial, so BIND would serve it instead of transferring, and the stale records
  would outlive the transfer that never happened. Provisioning deletes the file
  and its journal, and the first transfer creates them.
- `named-checkconf -z` loads zones, so it fails on a secondary before the
  transfer. The readiness unit therefore checks syntax, and the health check
  proves the zone answers.
- Unbound refuses to forward to a loopback address unless
  `do-not-query-localhost: no` is set, which reads like a contradiction.
- The package is built with `/etc/unbound` as its default chroot, and the unit
  is `Type=notify`. Inside that chroot the daemon cannot see
  `/run/systemd/notify` and exits at startup, while `unbound-checkconf` still
  reports the file as valid. The config clears the chroot.

## Proof

```proof
named-checkconf -z /etc/named.conf
```
