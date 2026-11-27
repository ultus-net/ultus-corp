# Isolation

A lab segment is a libvirt network with no `<forward>`, no `<dhcp>`, no
`<bridge name=` and `<dns enable='no'/>`. Guests reach each other on the
segment and reach nothing behind the host. libvirt has no `isolated` forward
mode; omitting `<forward>` entirely is what makes it isolated.

A bridge would put the lab on the host's LAN, and DHCP or libvirt DNS would
create a second source of addresses and names. The gate rejects all three, so a
network added later cannot quietly reintroduce them.

## Address plan

| Prefix | Use | In P0 |
| --- | --- | --- |
| `10.100.0.0/16` | primary DC and branches | yes |
| `10.101.0.0/16` | DR DC, evolution stage 3 | no |

Every scenario takes its CIDRs from `lab/lab.toml`. The gate renders them and
compares each one with the host's own plan.

## What the gate checks

`tests/test-isolation.sh` runs without a hypervisor or a live domain:

- every rendered network passes `check_network_isolated`, and
  `tests/fixtures/network-leaking.xml` fails the same function
- every lab CIDR is disjoint from `lab doctor --host-uplinks`
- every scenario stays within its declared VM and RAM budget
- the real tree passes the pins, manifest, secret, media and role-record checks,
  not only the fixtures

`lab doctor --host-uplinks` prints the addresses and connected routes of
physical interfaces plus the interface that carries the default route. It
ignores the lab's own bridges, so the comparison cannot flag the lab against
itself. A host with no uplink is a failure, not an empty pass.

## Before publishing

Run the gate, then read what git would publish:

```bash
bash tests/test-isolation.sh
git status --short
git ls-files | grep -E '\.(iso|qcow2|vhd|wim)$'
git ls-files lab-secrets
```

The secret scan reads the tree, not the history. It skips `run/`, `.git/`,
`lab-secrets/`, the deliberate leak fixtures and the check script that holds its
own patterns. Private key material, an age secret key and a YAML `PrivateKey=`
are findings.

The repo publishes generic names, reserved documentation addresses and no
client identity. `manifests/base.signer` stays empty until an operator records a
verified upstream identity, and `build/repin.sh` refuses to trust a digest
without one.
