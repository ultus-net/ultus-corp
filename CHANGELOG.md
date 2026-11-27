# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- feat: s2-dhcp proves a relayed lease across a Kea restart, a relay restart and a client reboot
- feat: the client role proves a DHCP lease with no added package
- feat: the dhcp role ships a Kea server and a dnsmasq relay
- refactor: share the deployment gate and the provision unit across roles
- feat: render a cross-site interface and a DHCP client mode
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
- fix: a role package lock now fails closed unless the core closure plus the recorded delta reproduces the built image; the delta is a set difference, so ordering and locale cannot change it, and the static gate proves the base pin reaches `Containerfile.core` through `base_ref`
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
- feat: deployment contract (Task 8): a lowercase UUIDv4 `deployment_id` in `meta-data` and `/run/ultus-corp/deployment-id`, the empty `ultus-role-install.target`, `ultus-deploy-finalize@.service` and `ultus-deploy-ready.target`; `finalize.sh` records id, booted digest, role and completion time under `/var/lib/ultus-corp/deployments/` and scrubs the cloud-init cache
- feat: `lab up` waits for the guest's deployment record over SSH, verifies it against the disk's recorded digest, keeps one record per id in `state.json`, ejects the seed from the live and persistent domain and deletes it; `lab/build-disk.sh` writes `<disk>.id` and `<disk>.digest` beside every disk so the handshake can fail closed
- feat: the applier is pulled in by `ultus-role-install.target`; it enables and restarts `named` and `unbound` after the configuration validates, so the first boot is in service before the ready target is reached
- feat: `tests/test-deploy.sh` proves the units, the record and the refusals inside the image; `tests/test_deploy.py` proves the handshake polling and the state history; `tests/scenarios/s1-dns.sh` adds gates 10 and 11: the managed manifest after readiness, after a second boot and after a hand edit, one record, a consumed seed and a scrubbed cache
- feat: CI (Task 9): `core` builds once and uploads the core ref, `build` rebuilds each role from that exact digest and pushes it, `supply` scans and signs the same digest, and the weekly repin verifies `manifests/base.signer` before it writes a pin; an unknown signer fails closed and opens no PR
- feat: greenboot rollback proof: `tests/test-greenboot.sh` proves the required check fails with no resolver and that `bootc rollback` exists; `tests/scenarios/greenboot-rollback.sh` switches a live host to a deliberately failing image and asserts the previous digest returns
- feat: isolation gate (Task 10): every rendered network carries no `<forward>`, DHCP, bridge or libvirt DNS, every lab range is disjoint from the host's uplinks, and every scenario stays within its declared VM and RAM budget; a leaking fixture must fail the same check
- feat: `lab doctor --host-uplinks` prints the host's physical address plan and ignores the lab's own bridges
- docs: `docs/runbooks/scenarios.md` records the deployment contract, the greenboot proof and the P0 acceptance line; `docs/runbooks/isolation.md` records the publish checks
- fix: the deployment read verifies the record it returns, so no caller can hold an unverified one; a record naming another role or digest fails at once instead of after the poll timeout
- fix: the rollback proof reads the guest's boot id, so a reboot that never happened fails fast rather than being absorbed by the rollback timeout; the failing layer is built from the image id recorded beside the disk, not from whatever the local tag points at
- fix: the isolation gate proves the path-scoped secret and media scans still catch the deliberate fixtures, and `lab doctor --host-uplinks` prints canonical networks that the gate parses strictly
- fix: the `s1-dns` negative zone assertion is a direct negative check, not a `grep … || true` that passes on empty output
- docs: plan status links PR #7 and keeps Task 11 open until the disk rebuild, because the cached disks predate the role image
- fix: the core ref records `<tag>@sha256:<id>`, the form `check_core_ref` and the CI digest comparison require; a bare id also made the local core cache miss on every run. `tests/test-image.sh` runs `check_core_ref` on the produced artifact, so the producer's format is gated instead of assumed
- fix: the supply job tracks `aquasecurity/trivy-action@master` (no moving major tag exists) and logs in once into a Docker authfile that trivy, syft and cosign all read; the signed digest comes from the pulled image instead of a skopeo lookup. GitHub Actions float on a moving ref: an exact guess broke CI before any step ran, and the pins that matter are the base image digest and the package locks
- fix: greenboot no longer judges an unprovisioned first boot, and no longer loses the check to an ordering cycle. The dns check failed on the image's default configuration before cloud-init had provisioned it, so a healthy host rolled back. Ordering the unit after `cloud-final.service` was the first attempt and is also wrong: the vendor unit is pulled by `multi-user.target` and cloud-final is ordered after it, so systemd deleted the check job and every green boot passed unproven. The check now reads `/var/lib/ultus-corp/deployments`: no record means an unprovisioned first boot is not judged, records mean the host is in service and the zone is checked, and a delivered id with no record fails closed after a bounded wait. The check refuses an id that is not the lowercase UUIDv4 the applier requires, so a shape the record path cannot hold never waits on a misleading timeout
- fix: `ultus-provision.service` no longer deadlocks the boot. It was ordered `Before=named.service unbound.service` and then called `systemctl restart` on them, so the queued restart waited for the applier to finish while the applier waited for the restart. The applier writes the delivered files before it restarts the services, so the ordering was unnecessary and is removed; `tests/test-deploy.sh` rejects it if it returns
- fix: hypervisor evidence runs on a host without GNU time. `lab/measure.py` reports wall seconds, the sampled qemu peak RSS of the processes the run started and the harness peak RSS, and the scenario scripts honour `LAB_RUN_DIR` instead of hardcoding `run/`, which the qemu user cannot traverse under a `0700` home
