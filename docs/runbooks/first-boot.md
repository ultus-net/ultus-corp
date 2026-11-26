# First boot: s0-base

`s0-base` proves the image thesis: one bootc image installs to a disk, boots
under KVM, and answers a DNS query, with no manual step.

## What runs

| Mechanism | Windows equivalent | Where the analogy breaks |
| --- | --- | --- |
| `bootc` installs the container image to the disk at build time | DISM applies a WIM to a partition | the image is an OCI container, so the same artifact is the build and the update |
| `cloud-init` NoCloud seed from a `cidata` ISO | unattend.xml on installation media | the seed is a separate read-only disk, re-read on every boot |
| `systemd` units order the boot | Service Control Manager | units declare dependencies, not a fixed start order |
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

## Host prerequisites

`lab doctor` names every gap. The package install and the daemon enable run
once, as root:

```bash
sudo pacman -S --needed libvirt qemu-full edk2-ovmf libisoburn dnsutils
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER"
```

`bootc-image-builder` needs rootful podman because it mounts loop devices, so
the disk build is the one step that escalates. Point `LAB_PODMAN` at it:

```bash
LAB_PODMAN='sudo podman' lab up s0-base
```

The qcow2 is cached under `build/vm/cache/<role>-<image-id>.qcow2`. A rebuilt
image gets a new id and therefore a new disk; the old entry is dropped by
`lab prune`.

## Known gaps

- The disk build needs the `bootc-image-builder` container and about 5 GiB of
  free space per role image.
- `lab down` removes the domain, volume, seed ISO and networks from state. With
  no state file, only `--force` works, and it deletes only names the spec
  derives for that scenario.
