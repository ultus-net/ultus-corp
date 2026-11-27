# Ultus Corp Lab Runner - CentOS Stream 10 Lab Environment

Public repository for a CentOS Stream 10 application lab built with `podman` and `libvirt`.

## Status

The P0 harness is in place and every local gate passes. The DNS scenario, the
deployment contract, the greenboot rollback proof, CI with keyless signing, and
the isolation gate are built. The hypervisor scenarios have not run since the
deployment-contract change replaced the role image, so the cached disks on this
host are stale: one rootful `bash lab/build-disk.sh dns build/vm/dns.qcow2`
precedes the next `s0-base`, `s1-dns` or rollback run.

## Documentation

- [Design](docs/superpowers/specs/2026-11-26-ultus-corp-design.md) and [P0 plan](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md)
- [Scenarios and budgets](docs/runbooks/scenarios.md)
- [Isolation](docs/runbooks/isolation.md)
- [First boot](docs/runbooks/first-boot.md)
- [Packages](docs/runbooks/packages.md)

[MIT License](LICENSE)
