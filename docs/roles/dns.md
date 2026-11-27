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
- The image ships no `named.conf`, no `unbound.conf` and no zone. The lab
  renderer writes all three from `lab/lab.toml` and the seed carries the final
  bytes, so no run's address is baked into a build.
- `ultus-provision.service` applies them before `named` and `unbound` start. It
  restores the SELinux labels cloud-init cannot set, deletes a zone file left by
  an earlier deployment on a secondary, and fails closed if the seed delivered
  no configuration.
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
The rendered configuration is the Group Policy equivalent, except that it is
applied once at deployment and never converges afterwards.

## Where it breaks

- BIND and Unbound cannot both bind `127.0.0.1:53`. BIND therefore takes the
  node's first interface address and Unbound owns loopback, which is also why
  the health check queries `127.0.0.1` and not the node address.
- A zone file is deployment data, not image data. The renderer derives every `A`
  record from the spec and the delegation glue from the `[dns]` table, so the
  addresses exist only in the seed.
- A secondary must not keep a zone file. A copy carries the master's serial, so
  BIND would serve it instead of transferring. The seed gives a secondary no
  zone at all, and provisioning deletes any file an earlier deployment left.
- `named-checkconf -z` loads zones, so it fails on a secondary before the
  transfer. The readiness unit therefore checks syntax, and the health check
  proves the zone answers.
- Unbound refuses to forward to a loopback address unless
  `do-not-query-localhost: no` is set, which reads like a contradiction.
- The package is built with `/etc/unbound` as its default chroot, and the unit
  is `Type=notify`. Inside that chroot the daemon cannot see
  `/run/systemd/notify` and exits at startup, while `unbound-checkconf` still
  reports the file as valid. The rendered config clears the chroot.
- cloud-init writes the delivered files as an unconfined process, so they
  inherit the parent directory's label. A confined `named` cannot read
  `etc_t` as `named_conf_t`, which is why the applier runs `restorecon` before
  the syntax check.

## Proof

```proof
test -x /usr/libexec/ultus-corp/provision.sh && systemctl is-enabled ultus-provision.service && rpm -q bind unbound
```
