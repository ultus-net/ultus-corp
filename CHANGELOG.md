# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- feat: repository skeleton, evidence recorder and static gate ([Task 1](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md))
- feat: pinned base, build argument and first role image ([Task 2](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md)); each gate now writes its own evidence file under `run/evidence/`
- feat: dns role with zone, boot provisioning and package lock ([Task 3](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md)); the lock excludes `gpg-pubkey` pseudo-packages, which are not installable
- feat: lab CLI with typed state and explicit teardown contract ([Task 5](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md)); the test substitutes a fake virsh and disk builder, so it runs on a host with no libvirt
- feat: seed ISO, SSH key injection and image-builder wiring for s0-base ([Task 6](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md), boot gate unverified until libvirt and xorriso are installed)
- fix: the disk build states the rootful podman contract through `LAB_PODMAN` and caches the qcow2 per image id; `lab doctor` names both gaps
- fix: the guest boots: libvirt has no `isolated` forward mode, `qemu64` lacks SSE4.2, the daemon needs absolute disk paths, and cloud-init 24.4 rejects `to: default` in network-config v2
- fix: the node derives its zone from the seed: the owner-name rewrite now matches the bare `dns-a` token, `unbound.service` is enabled, and the base module enables `greenboot-healthcheck.service`
- fix: the run tree can move with `LAB_RUN_DIR`, because the qemu user cannot traverse a `0700` home, and `lab doctor` names the fix
- fix: a disk build can no longer come from a stale tag: every cache miss reloads the image into the build storage and fails on an id mismatch, and each build writes into a private output directory
- fix: a cache hit proves its own origin through a `<disk>.id` sidecar, so a disk stored under the wrong image id is rebuilt rather than served; `lab doctor` counts an unproven disk as uncached
- docs: plan corrections from the consistency audit: DC-scoped DNS nodes, scenario-scoped network names, seed directory instead of an ISO, real-tree gates, host prerequisites
- docs: operator confirms hub-and-spoke with a primary DC, a DR DC and three branches; the DR DC is evolution stage 3 and outside P0
- docs: Task 2 creates `modules/base/` so the first image build has a `COPY modules/` source
- docs: Task 2 and Task 3 corrected against the real build: role-scoped `COPY`, lock build before the package test, lock consumption rebuild
