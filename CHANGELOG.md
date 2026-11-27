# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- chore: merge the updated design from `main` and the delivery model from `docs/branch-footprint`, which `main` never received; the design now carries one sequence of decisions D1 to D33 and gates 1 to 16
- feat: repository skeleton, evidence recorder and static gate ([Task 1](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md))
- feat: pinned base, build argument and first role image ([Task 2](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md)); each gate now writes its own evidence file under `run/evidence/`
- feat: core image split; `Containerfile.core` builds the shared layer from the pinned base and every role is `FROM` the core digest, so the common package set and `modules/base/` live in one place ([Task 2](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md))
- feat: dns role with zone, boot provisioning and package lock ([Task 3](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md)); the lock excludes `gpg-pubkey` pseudo-packages, which are not installable
- feat: the lab renders `named.conf`, `unbound.conf` and the zone from `lab/lab.toml`; the image ships none of them, and `provision.sh` applies what the seed delivered, deletes a stale secondary zone, restores SELinux labels and fails closed ([Task 3](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md))
- feat: lab CLI with typed state and explicit teardown contract ([Task 5](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md)); the test substitutes a fake virsh and disk builder, so it runs on a host with no libvirt
- feat: seed ISO, SSH key injection and image-builder wiring for s0-base ([Task 6](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md))
- feat: the boot gate passes end to end: `s0-base` installs to disk, boots, resolves its own zone and answers a DNS query from the host, then tears down with no domain, network, volume or seed left (`run/evidence/s0-base.log`)
- feat: `s1-dns` pairs a primary with a secondary that copies the zone, delegates `ipa.lab.internal`, and keeps answering while the primary is suspended ([Task 7](docs/superpowers/plans/2026-11-26-ultus-corp-plan.md)); the spec's `secondary` names a node, and the renderer resolves it to an address for `masters`
- feat: `tests/test-provision.sh` proves both role stanzas inside the image, and the packages gate now starts `unbound` and checks it binds `127.0.0.1:53`
- fix: the core build is keyed on the hash of every input it consumes, so a moved base pin, an edited common manifest or a changed `modules/base/` file rebuilds it instead of reusing a stale image
- fix: a role package lock now fails closed unless the core closure plus the recorded delta reproduces the built image, and the static gate proves the base pin reaches `Containerfile.core` through `base_ref`
- fix: the disk build states the rootful podman contract through `LAB_PODMAN` and caches the qcow2 per image id; `lab doctor` names both gaps
- fix: the guest boots: libvirt has no `isolated` forward mode, `qemu64` lacks SSE4.2, the daemon needs absolute disk paths, and cloud-init 24.4 rejects `to: default` in network-config v2
- fix: the node derives its zone from the seed: the owner-name rewrite now matches the bare `dns-a` token, `unbound.service` is enabled, and the base module enables `greenboot-healthcheck.service`
- fix: the run tree can move with `LAB_RUN_DIR`, because the qemu user cannot traverse a `0700` home, and `lab doctor` names the fix
- fix: a disk build can no longer come from a stale tag: every cache miss reloads the image into the build storage and fails on an id mismatch, and each build writes into a private output directory
- fix: a cache hit proves its own origin through a `<disk>.id` sidecar, so a disk stored under the wrong image id is rebuilt rather than served; `lab doctor` counts an unproven disk as uncached
- fix: the dns node resolves its own zone: `unbound` died at startup inside the package's default `/etc/unbound` chroot, and the health check read `dig`'s error text as an answer
- fix: the s0-base gate waits for each service, not for the NIC: a ping passed while `cloud-init` was still starting `named`
- docs: plan corrections from the consistency audit: DC-scoped DNS nodes, scenario-scoped network names, seed directory instead of an ISO, real-tree gates, host prerequisites
- docs: operator confirms hub-and-spoke with a primary DC, a DR DC and three branches; the DR DC is evolution stage 3 and outside P0
- docs: Task 2 creates `modules/base/` so the first image build has a `COPY modules/` source
- docs: Task 2 and Task 3 corrected against the real build: role-scoped `COPY`, lock build before the package test, lock consumption rebuild
