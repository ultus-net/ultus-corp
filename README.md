# Ultus Corp Lab Runner - CentOS Stream 10 Lab Environment

Public repository for a CentOS Stream 10 application lab built with `podman` and `libvirt`.

## Status

The P0 harness and the `s0-base` boot are in place. The DNS scenario, the
deployment contract, the greenboot rollback proof, CI with keyless signing, and
the isolation gate are built and pass their local gates. `s1-dns` and the
rollback proof still need a rootful disk build before their hypervisor evidence
lands.

## Documentation

- [Design](docs/superpowers/specs/2026-11-26-ultus-corp-design.md) and [P0 plan](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md)
- [Scenarios and budgets](docs/runbooks/scenarios.md)
- [Isolation](docs/runbooks/isolation.md)
- [First boot](docs/runbooks/first-boot.md)
- [Packages](docs/runbooks/packages.md)

[MIT License](LICENSE)
