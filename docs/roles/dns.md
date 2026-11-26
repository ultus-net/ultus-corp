# dns role

BIND 9 is the authoritative server for `lab.internal`. Unbound is the recursive
resolver for the node. Both listen on loopback, so a node can answer its own
lookups before any other host exists.

## Linux mechanism

- `named` serves `lab.internal` from `/var/named/lab.internal.zone`, with
  recursion off and no zone transfers.
- `unbound` listens on `127.0.0.1:53`, forwards `lab.internal` to the
  authoritative address, and resolves everything else recursively.
- `ultus-provision.service` runs before `named` and rewrites both files from
  `/run/ultus-corp/node.json`: the authoritative listen address, the unbound
  forwarder, the zone's owner name and the zone's address.
- `ultus-dns-ready.service` runs `named-checkconf -z` so a broken zone fails the
  boot visibly.
- `50-dns-health.sh` sits in `/etc/greenboot/check/required.d` and queries
  `127.0.0.1`, so a node that boots but cannot answer rolls back.

## Windows concept

The pair maps to an AD-integrated DNS server plus a forwarder, or to DNS Server
with a conditional forwarder. The zone is the AD domain zone, the forwarder is
the recursive resolver, and Group Policy equivalent is the generated config.

## Where it breaks

- BIND and Unbound cannot both bind `127.0.0.1:53`. The image therefore gives
  BIND `127.0.0.2` at build time and moves it to the node address at boot.
- A zone file written at build time cannot carry a per-run address. The image
  ships a placeholder record for `dns-a` on `127.0.0.2`, and provisioning
  rewrites the owner name and the address to the node's own. The rewrite is
  idempotent, and a secondary node replaces the file with the transferred zone.
- Unbound refuses to forward to a loopback address unless
  `do-not-query-localhost: no` is set, which reads like a contradiction.
- A secondary node needs the primary's address in `secondary` in
  `node.json`. Without it the node is a primary and owns the zone file.

## Proof

```proof
named-checkconf -z /etc/named.conf
```
