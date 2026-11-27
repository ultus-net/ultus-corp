# dhcp role

Kea serves DHCPv4 for the branch segment. dnsmasq relays a request from that
segment to the server across the routed DC network. Both are the same image,
selected by the node's `profile`.

## Linux mechanism

- The `server` profile runs `kea-dhcp4` from `/etc/kea/kea-dhcp4.conf`. The
  config declares the branch subnet and its pool, and names the relay's branch
  address so Kea accepts a request that arrives through it. The lease database
  is Kea's memfile backend, a CSV file at `/var/lib/kea/kea-leases4.csv`.
- The `relay` profile runs `dnsmasq` from `/etc/ultus-corp/dhcp-relay.conf`.
  The file sets `port=0`, so dnsmasq never answers DNS, and carries one
  `dhcp-relay=<relay address>,<server address>` line. The relay forwards and
  serves nothing itself.
- The kea package ships a sample at the path Kea reads when it is given no
  configuration, so the build removes it. The image therefore carries no
  `kea-dhcp4.conf` and no `dhcp-relay.conf`: the lab renderer writes both from
  `lab/lab.toml`, and the seed delivers the final bytes, so no run's address is
  baked into a build.
- `ultus-provision.service` is pulled in by `ultus-role-install.target`, which
  `cloud-init` starts after the seed is written. It reads `profile` from
  `/run/ultus-corp/node.json`, restores the SELinux labels cloud-init cannot
  set, validates the delivered file with `kea-dhcp4 -t` or `dnsmasq --test`,
  and fails closed on an absent file or an unknown profile.
- On a server the applier enables and restarts `kea-dhcp4.service`, and
  requires it active. On a relay it enables and restarts
  `ultus-dhcp-relay.service`, and requires it active. The vendor `kea-dhcp4`
  and `dnsmasq` units are disabled in the image, so a boot that has not been
  provisioned raises no service against an absent configuration.
- `ultus-dhcp-relay.service` turns on `net.ipv4.ip_forward` in `ExecStartPre`
  through `relay-prepare.sh`, then runs dnsmasq in the foreground with an empty
  `--pid-file=`. The forward flag is a precondition of relaying, so a host that
  cannot set it fails the start.
- `50-dhcp-health.sh` sits in `/etc/greenboot/check/required.d`. On a server it
  sends `status-get` over the Unix control socket
  `/var/run/kea/kea4-ctrl-socket` and requires `result` 0 with the socket
  `ready`. On a relay it requires `ultus-dhcp-relay.service` active and
  `ip_forward` on. A failing required check keeps `boot-complete.target`
  unreached, so greenboot rolls the host back to the previous deployment.

## Windows concept

The pair maps to the Windows DHCP Server role with a DHCP relay agent: a scope
on the server, and `netsh dhcp` plus the Routing and Remote Access relay agent
on the segment that has no server. The rendered configuration is the Group
Policy equivalent for the scope and the relay, except that it is applied once
at deployment and never converges afterwards.

## Where it breaks

- Kea is the server and dnsmasq is only the relay. Windows ships both the
  server and the relay agent as features of one role; here two packages fill
  the two halves, and only one runs on a node.
- The relay is a separate profile of the same image, not a feature switch on a
  server. A node is built for one of the two jobs, and the applier refuses a
  profile that is neither.
- The lease file is memfile CSV, not the Jet database Windows keeps. A lease
  survives a Kea restart because the file holds it, but it is not a service
  database and nothing else may write it.
- The server sends no `routers` option. The branch edge that would be the
  default gateway does not exist yet, so a client that took a router from DHCP
  would point at an address nothing answers on. The option arrives with the
  branch edge.
- dnsmasq in this build rejects `--no-pid`, so the unit disables the pid file
  with an empty `--pid-file=` instead. `port=0` is what stops it answering DNS;
  a relay that kept a DNS port would shadow the site resolver.

## Proof

```proof
test -x /usr/libexec/ultus-corp/provision.sh && systemctl is-enabled ultus-provision.service && rpm -q kea dnsmasq
```
