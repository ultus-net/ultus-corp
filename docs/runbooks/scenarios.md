# Scenarios

One scenario is resident at a time. `lab up` creates its networks, seeds,
volumes and domains, and `lab test` runs the matching script under
`tests/scenarios/`. Gate 5 requires `lab down` to leave no domain, no network,
no volume and no seed, so a failed teardown keeps its state file and fails
loudly for review.

## Budgets

Each `[[scenario]]` in `lab/lab.toml` declares `vm_budget` and
`ram_budget_mib`. `tests/test-isolation.sh` renders every scenario and fails if
the node count or the RAM sum exceeds the declaration. The P0 ceilings are five
VMs and 10 GiB.

| Scenario | Nodes | RAM | Budget | Purpose |
| --- | --- | --- | --- | --- |
| `s0-base` | 1 | 1024 MiB | 1 VM, 2048 MiB | one image installs, boots, resolves its zone |
| `s1-dns` | 2 | 2048 MiB | 2 VMs, 3072 MiB | primary and secondary zone transfer |
| `s2-dhcp` | 3 | 3072 MiB | 3 VMs, 3072 MiB | relayed lease survives a restart |

## Rebuild rule and measurements

A scenario rebuilds from an empty host in under ten minutes once its role image
is cached: `lab down`, `lab prune`, `lab up`, `lab test`. The clock starts at
`lab up` and stops when the last assertion records. The ten minutes exclude the
one-off disk build, which is why the disk is cached per image id.

| Scenario | Wall time | Peak RSS | Measured |
| --- | --- | --- | --- |
| `s0-base` | unset | unset | pending the rebuild after the deployment-contract change |
| `s1-dns` | unset | unset | pending the rebuild after the deployment-contract change |
| `s2-dhcp` | unset | unset | pending the first hypervisor run |

The measurement command is:

```bash
python3 lab/measure.py bash tests/scenarios/s1-dns.sh
```

`measure.py` reports wall seconds, the sampled peak RSS of the qemu processes
(the guest footprint), and the peak RSS of the harness's own children. GNU time
is not required. The numbers stay unset until that run. An estimate is not
evidence. The deployment-contract change replaced the role image, so the cached
disks on this host predate it and the next run needs one rootful disk build
first.

## Deployment contract

Every seed carries a lowercase UUIDv4 `deployment_id`. `cloud-init` writes it to
`/run/ultus-corp/deployment-id`, starts `ultus-role-install.target`, and enables
`ultus-deploy-finalize@<id>.service` before it starts `ultus-deploy-ready.target`
without blocking.

| Unit | Contract |
| --- | --- |
| `ultus-role-install.target` | every image ships it, empty unless the role adds an installer |
| `ultus-provision.service` | role installer, `Before=` the role target; it restarts the vendor services itself, so it is not ordered against them |
| `ultus-deploy-finalize@.service` | runs after `cloud-final` and the role target, once per id |
| `ultus-deploy-ready.target` | started by `cloud-final` after the instance is enabled, so it pulls it in |

`finalize.sh` records the id, the digest from `bootc status`, the role and the
completion time under `/var/lib/ultus-corp/deployments/<id>.json`. It then
scrubs `/var/lib/cloud/instance` and `/var/lib/cloud/instances`. `lab up` copies
the record into `run/<scenario>/state.json` under `deployments[<id>]`, ejects the
seed from the live and persistent domain, deletes the ISO and the seed
directory, and marks both resources consumed.

A second boot must not rewrite a managed file. Gate 10 compares the manifest
after readiness and after a reboot, and requires that a hand edit of
`/etc/named.conf` fails the same comparison.

The record is read over SSH with host-key checking disabled, because each run
reuses an address and a remembered key would be stale rather than protective.
That trust is scoped to an ephemeral guest on an isolated segment. Do not copy
the option into a harness that reaches a persistent host.

## Greenboot rollback

`50-dns-health.sh`, `50-dhcp-health.sh` and `50-client-health.sh` are required
greenboot checks. The dns check proves the zone answers, the dhcp check proves
Kea's control socket is ready or the relay is active with `ip_forward` on, and
the client check proves a lease on a declared DHCP interface. A failing required
check keeps `boot-complete.target` from being reached, and greenboot rolls the
host back to the previous deployment after `GREENBOOT_MAX_BOOT_ATTEMPTS`.

The vendor unit is pulled into the `multi-user.target` transaction, and
cloud-init's final stage is ordered after `multi-user.target`. Ordering the check
after `cloud-final.service` therefore builds a cycle, and systemd deletes the
check job: a green boot then passes unproven. The check reads the durable record
instead. With no record under `/var/lib/ultus-corp/deployments`, the first boot
has not been provisioned yet and is not judged. With records present the host has
been in service, so the zone check runs. A delivered deployment id with no record
is an unfinished deployment, and the check waits for it and then fails closed.
The harness still proves the deployment, because `lab up` waits for the record
and fails when it never arrives.

`tests/scenarios/greenboot-rollback.sh` builds a throwaway image from the dns
image with a failing check under `/usr/lib/greenboot/check/required.d/`, loads it
into the guest from a raw disk, switches with
`bootc switch --transport containers-storage`, and asserts the host returns to
the previous digest. The check leaves a marker on `/var`, which survives the
rollback, so a green boot cannot pass without the failing boot having run.

## Mechanism map

| Linux mechanism | Windows equivalent | Where the analogy breaks |
| --- | --- | --- |
| `bootc` installs an OCI image to disk | DISM applies a WIM | the same artifact is the build and the update |
| NoCloud seed on a `cidata` ISO | unattend.xml | the seed is a separate read-only disk |
| `systemd` targets and ordering | Service Control Manager | dependencies are declared, not a fixed start order |
| libvirt isolated network | internal Hyper-V switch | no DHCP or DNS unless a guest provides it |
| greenboot required checks | boot success policies | the rollback is an image switch, not a repair |

## Acceptance line

The P0 gate, run from the repository root:

```bash
bash tests/test-static.sh &&
bash tests/test-image.sh dns &&
bash tests/test-packages.sh &&
bash tests/test-provision.sh &&
bash tests/test-deploy.sh &&
bash tests/test-dhcp.sh &&
bash tests/test-client.sh &&
bash tests/test-greenboot.sh &&
python3 -m unittest tests.test_render tests.test_deploy &&
bash tests/test-lab.sh &&
bash tests/test-ci.sh &&
bash tests/test-isolation.sh
```

The hypervisor scenarios are separate, because they need a cached disk built by
root:

```bash
bash tests/scenarios/s0-base.sh
bash tests/scenarios/s1-dns.sh
bash tests/scenarios/s2-dhcp.sh
bash tests/scenarios/greenboot-rollback.sh
```

Set `LAB_RUN_DIR` to a directory the qemu user can traverse when the checkout
sits under a `0700` home; `lab` and the scenario scripts read the same variable.
The evidence still lands in `run/evidence/`.
