# First boot: s0-base

`s0-base` proves the image thesis: one bootc image installs to a disk, boots
under KVM, and answers a DNS query, with no manual step.

## What runs

| Mechanism | Windows equivalent | Where the analogy breaks |
| --- | --- | --- |
| `bootc` installs the container image to the disk at build time | DISM applies a WIM to a partition | the image is an OCI container, so the same artifact is the build and the update |
| `cloud-init` NoCloud seed from a `cidata` ISO | unattend.xml on installation media | the seed is a separate read-only disk, re-read on every boot |
| `systemd` units order the boot | Service Control Manager | units declare dependencies, not a fixed start order |
| `ultus-role-install.target` and `ultus-deploy-finalize@` close the deployment | first-boot scripts and a completion registry entry | the record is keyed by deployment id, and a second boot must not rewrite it |
| `qemu-guest-agent` reports to the hypervisor | Hyper-V integration services | it is optional, and its channel is a virtio device |
| libvirt isolated network | an internal Hyper-V virtual switch | there is no DHCP or DNS on the segment unless a guest provides it |

## Procedure

```bash
lab doctor
lab up s0-base
bash tests/scenarios/s0-base.sh
```

`lab up` generates `lab-secrets/id_ed25519` on first use, writes the NoCloud
seed, builds `<node>-seed.iso` with `xorriso`, asks `lab/build-disk.sh` for a
qcow2, then defines and starts the domain.

## Second scenario: `s1-dns`

`bash tests/scenarios/s1-dns.sh` runs a primary and a secondary of the same
image. It proves the zone transfer two ways: the secondary answers the primary's
record, and it keeps answering while the primary is suspended. The gate resumes
the primary and tears both nodes down.

Both nodes need one cached disk, because they share the image. A rebuilt dns
image costs one rootful `lab/build-disk.sh` run, as for any other role.

## Deployment and the second boot

Each seed carries a UUIDv4 `deployment_id`. `cloud-init` writes it to
`/run/ultus-corp/deployment-id`, starts `ultus-role-install.target`, and enables
`ultus-deploy-finalize@<id>.service` before it asks
`ultus-deploy-ready.target` to start. The target pulls the enabled instance in,
so the record lands after `cloud-final` and after the role install.

`finalize.sh` writes `/var/lib/ultus-corp/deployments/<id>.json` with the id,
the digest from `bootc status`, the role and the completion time, then scrubs
the cloud-init instance cache. `lab up` reads that record over SSH, copies it
into `run/<scenario>/state.json`, ejects the seed from both the live and the
persistent domain, and deletes the ISO and the seed directory.

The second boot must not rewrite a managed file. `tests/scenarios/s1-dns.sh`
compares `run/s1-dns/render/<node>.managed-files.sha256` after readiness, after
a reboot, and after a hand edit of `/etc/named.conf`, which must fail the same
comparison. The deployment contract and the budgets are in
[scenarios.md](scenarios.md).

## Host prerequisites

`lab doctor` names every gap. The package install and the daemon enable run
once, as root:

```bash
sudo pacman -S --needed libvirt qemu-full edk2-ovmf libisoburn dnsutils
sudo systemctl enable --now libvirtd
```

On this host the libvirt socket is world-accessible, so no group membership is
needed. Where it is `0660 root:libvirt` instead, add `sudo usermod -aG libvirt
"$USER"` and start a new login session.

The run tree has to be traversable by the qemu user, and a `0700` home is the
common case that breaks it. Keep the default and relax the home, or relocate:

```bash
chmod o+x ~
# or
export LAB_RUN_DIR=/var/tmp/ultus-corp
```

`lab doctor` reports this as "unreachable for the qemu user" and names both
remedies. Domain XML always carries absolute paths, so the relocation is free.

`bootc-image-builder` needs rootful podman because it mounts loop devices, so
the disk build is the one step that escalates. Point `LAB_PODMAN` at it:

```bash
LAB_PODMAN='sudo podman' lab up s0-base
```

The qcow2 is cached under `build/vm/cache/<role>-<image-id>.qcow2`. A rebuilt
image gets a new id and therefore a new disk; the old entry is dropped by
`lab prune`.

Every cache miss copies the image into the build storage before the builder
runs, then compares the id it landed on. A tag that already existed there can
carry an older image, and a builder fed that tag emits a disk with none of the
new module code. The comparison turns that silent staleness into a failed
build.

A cache hit needs the id recorded beside the disk in `<disk>.id`. A disk whose
origin is unrecorded is rebuilt rather than trusted, and `lab doctor` still
asks for rootful podman while one is pending.

## Known gaps

- The disk build needs the `bootc-image-builder` container and about 5 GiB of
  free space per role image.
- `lab down` removes the domain, volume, seed ISO and networks from state. With
  no state file, only `--force` works, and it deletes only names the spec
  derives for that scenario.
