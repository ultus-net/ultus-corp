# P0 Scenario Harness and the DNS Scenario: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the repo skeleton, the scenario harness, and the first two runnable scenarios (`s0-base` and `s1-dns`) so every later role inherits a working build, boot, test and teardown cycle.

**Architecture:** One `Containerfile.<role>` per role, all `FROM` one digest-pinned CentOS Stream 10 bootc base. A stdlib-only Python renderer turns `lab/lab.toml` into libvirt domain XML plus a NoCloud seed ISO. A single `lab` CLI runs one scenario at a time and records what it created, so `lab down` is exact.

**Tech Stack:** CentOS Stream 10 image mode, bootc, Podman, BIND 9, Unbound, libvirt/KVM, Python 3 stdlib (`tomllib`), bash test harness.

**Spec:** `docs/superpowers/specs/2026-11-26-ultus-corp-design.md`

## Global Constraints

- Base image: `quay.io/centos-bootc/centos-bootc:stream10@sha256:0df2ed8fd881b36b34f559c59eb5c4a51992f69b1ce05203307ce29ed1a76f87`, tag and digest both present.
- Guests are CentOS Stream 10 only. No Fedora, Ubuntu or Debian guest.
- One scenario resident at a time. A single scenario stays under 5 VMs and 10 GiB RAM.
- `lab down` leaves no domain, network, volume or generated key, and a second `lab up` succeeds.
- No libvirt network may forward to the host LAN. No bridge, route or passthrough mode.
- Secrets never enter git, an image, or a rendered file inside the tree. `lab-secrets/` is gitignored.
- Renderer uses the Python standard library only. No PyYAML, no external YAML parser.
- Repo is public, MIT, generic. No client name and no real address.
- Commit subjects use `feat:`/`fix:`/`chore:`/`docs:`/`test:` and one logical change per commit.

## Review Focus

- A failed `lab up` leaves half its objects behind. Expectation: the next `up` or `down` recovers without manual `virsh` cleanup.
- Two scenarios pick the same libvirt network or volume name. Expectation: names are scenario-scoped, so both can exist sequentially.
- The host's own address space overlaps a lab prefix. Expectation: the isolation gate fails the build, not the lab.
- A role package is absent from Stream 10. Expectation: the build fails at a named package, not at boot.
- libvirt's own dnsmasq answers a lookup. Expectation: the scenario is defined with no libvirt DHCP and no libvirt DNS, so a green lookup came from the guest.
- A seed ISO is regenerated with a stale key. Expectation: each `up` writes a fresh seed and refuses to reuse a key already claimed by another host.

---

### Task 1: Repository skeleton and the static gate

**Files:**
- Create: `README.md`, `LICENSE`, `CHANGELOG.md`
- Modify: `.gitignore` (shipped at bootstrap; confirm every excluded path)
- Create: `build/checks.sh`
- Create: `tests/lib.sh`, `tests/test-static.sh`
- Create: `tests/fixtures/Containerfile.pinned`, `tests/fixtures/Containerfile.unpinned`
- Create: `tests/fixtures/packages-multi.txt`, `tests/fixtures/packages-ok.txt`
- Create: `tests/fixtures/leak-key.txt`, `tests/fixtures/leak-clean.txt`

**Interfaces:**
- Produces: `build/checks.sh` pure functions, each returning 0 when the tree is clean and 1 with a one-line reason on stdout:
  - `check_base_pin <file>...`
  - `check_manifest_one_per_line <file>...`
  - `check_no_secret_patterns <dir>`
  - `check_no_install_media <dir>`
- Produces: `tests/lib.sh` functions `assert_ok "name" cmd...` and `assert_fails "name" cmd...`, each printing `ok <name>` or `FAIL <name>: <reason>` and incrementing `FAILURES`.

- [ ] **Step 1: Write the failing test**

`tests/test-static.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh

assert_ok    "pinned base accepted"            check_base_pin tests/fixtures/Containerfile.pinned
assert_fails "unpinned base rejected"          check_base_pin tests/fixtures/Containerfile.unpinned
assert_ok    "one package per line accepted"   check_manifest_one_per_line tests/fixtures/packages-ok.txt
assert_fails "two packages on one line rejected" check_manifest_one_per_line tests/fixtures/packages-multi.txt
assert_fails "key material in tree rejected"   check_no_secret_patterns tests/fixtures
assert_ok    "clean file accepted"             check_no_secret_patterns tests/fixtures/leak-clean.txt

if [ "$FAILURES" -ne 0 ]; then echo "$FAILURES failing"; exit 1; fi
echo "static gate passed"
```

Fixture contents: `Containerfile.pinned` has
`FROM quay.io/centos-bootc/centos-bootc:stream10@sha256:` followed by 64 hex
characters. `Containerfile.unpinned` has the same line without the digest.
`packages-multi.txt` has one line with `bind unbound`. `packages-ok.txt` has
one package per line. `leak-key.txt` holds one line carrying the standard
private-key armour banner, spelled with spaces so the fixture is unambiguous.
`leak-clean.txt` holds an unrelated comment.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-static.sh`
Expected: FAIL, `build/checks.sh: No such file` or `check_base_pin: command not found`.

- [ ] **Step 3: Implement `build/checks.sh` and `tests/lib.sh`**

`check_base_pin` accepts a `FROM` line whose image reference matches
`:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$`. It skips `FROM scratch`, so a
multi-stage file is checked on its non-scratch stage only.
`check_manifest_one_per_line` rejects any non-comment line with whitespace
after trimming. `check_no_secret_patterns` greps for a private-key armour
banner, an age secret-key prefix, and a `lab-secrets/` path outside
`.gitignore`. `check_no_install_media` rejects `*.iso`, `*.vhd`, `*.qcow2` and
`*.wim` in the tree unless the path is under `run/`.

`tests/lib.sh` sets `FAILURES=0` and implements the two assertions with
`set +e` around the command so a failure prints the captured reason.

Create `.gitignore` with `run/`, `lab-secrets/`, `build/vm/`, `*.qcow2`,
`*.iso`, `.venv/`.

Create `README.md` with the spec link and status line, `LICENSE` with MIT
text, and `CHANGELOG.md` with an `## Unreleased` section and one entry.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-static.sh`
Expected: `static gate passed`.

- [ ] **Step 5: Commit**

```bash
git add README.md LICENSE CHANGELOG.md .gitignore build/checks.sh tests/
git commit -m "feat: repo skeleton and static gate"
```

---

### Task 2: Base pin, common manifest, and the first image build

**Files:**
- Create: `manifests/base.txt`, `manifests/packages-common.txt`
- Create: `build/common.sh`, `build/manifest.sh`
- Create: `Containerfile.dns`
- Create: `tests/test-image.sh`

**Interfaces:**
- Consumes: `check_base_pin` from Task 1.
- Produces: `build/common.sh` function `build_role <role>` which builds
  `localhost/ultus-corp/<role>:local` from `Containerfile.<role>` and then runs
  `bootc container lint` inside that image.
- Produces: `lab_image <role>` printing the full image reference
  `localhost/ultus-corp/<role>:local`, used by the renderer in Task 4.

- [ ] **Step 1: Write the failing test**

`tests/test-image.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
role=${1:?usage: test-image.sh <role>}
. build/common.sh

assert_ok "image builds and lints" build_role "$role"
assert_ok "base package installed" \
  podman run --rm "$(lab_image "$role")" rpm -q podman
assert_ok "base is CentOS Stream 10" \
  podman run --rm "$(lab_image "$role")" grep -q '^VERSION_ID="10"' /etc/os-release

if [ "$FAILURES" -ne 0 ]; then exit 1; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-image.sh dns`
Expected: FAIL, `Containerfile.dns: no such file`.

- [ ] **Step 3: Write the base pin, manifests and build script**

`manifests/base.txt` holds exactly one line, the pinned reference from Global
Constraints. `build/manifest.sh` joins `manifests/packages-common.txt` with
`manifests/packages-<role>.txt`, sorts and de-duplicates into
`build/out/packages-<role>.txt`.

`manifests/packages-common.txt`, one per line:
`cloud-init`, `openssh-server`, `qemu-guest-agent`, `sudo`, `podman`,
`nftables`, `policycoreutils`, `selinux-policy-targeted`, `chrony`.

`build/common.sh` defines `lab_image`, `base_ref` (reads `manifests/base.txt`),
and `build_role`. `build_role` runs `podman build --pull=never -f
Containerfile.<role> -t "$(lab_image <role>)" .` then
`podman run --rm "$(lab_image <role>)" bootc container lint`.

`Containerfile.dns`: a `ctx` stage copying `build/`, `manifests/` and
`modules/`, then `FROM $(base_ref)`, copying the joined manifest to
`/tmp/packages.txt` and running `dnf -y install $(cat /tmp/packages.txt)` in a
single layer, cleaning the dnf cache. The lint runs from the build script
rather than the file, so it runs even on a cached build.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-image.sh dns`
Expected: all `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add manifests build Containerfile.dns tests/test-image.sh
git commit -m "feat: pinned base and the first role image"
```

---

### Task 3: The dns role, and the package-availability gate

**Files:**
- Create: `manifests/packages-dns.txt`
- Create: `modules/dns/usr/libexec/ultus-corp/build.d/50-dns.sh`
- Create: `modules/dns/etc/named.conf`, `modules/dns/etc/unbound/unbound.conf`
- Create: `modules/dns/usr/lib/systemd/system/ultus-dns-ready.service`
- Modify: `Containerfile.dns` (copy `modules/dns/` onto `/`, run `build.d`)
- Create: `tests/test-packages.sh`

**Interfaces:**
- Consumes: `build_role`, `lab_image` from Task 2.
- Produces: the `dns` image with `named` and `unbound` enabled and validated.
  Later tasks rely on `/usr/libexec/ultus-corp/build.d/` running in name order.

- [ ] **Step 1: Write the failing test**

`tests/test-packages.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/common.sh
img=$(lab_image dns)

assert_ok "bind installed"       podman run --rm "$img" rpm -q bind
assert_ok "unbound installed"    podman run --rm "$img" rpm -q unbound
assert_ok "named config valid"   podman run --rm "$img" named-checkconf -z /etc/named.conf
assert_ok "unbound config valid" podman run --rm "$img" unbound-checkconf /etc/unbound/unbound.conf
assert_ok "named enabled"        podman run --rm "$img" systemctl is-enabled named

if [ "$FAILURES" -ne 0 ]; then exit 1; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-packages.sh`
Expected: FAIL, `bind installed: package bind is not installed`.

- [ ] **Step 3: Add the role**

`manifests/packages-dns.txt`, one per line: `bind`, `bind-utils`, `unbound`.

`50-dns.sh` runs `systemctl enable named unbound`, then asserts both are
enabled with `systemctl is-enabled`, exiting non-zero with the unit name on
failure.

`named.conf` binds the primary's service address on `:53`, serves
`lab.internal` from `/var/named/lab.internal.zone`, and forwards nothing.
`unbound.conf` binds the loopback and management addresses on `:53`, with a
forward zone for `lab.internal` pointing at the primary's address. No address is
held by both daemons.

`ultus-dns-ready.service` is a `Type=oneshot` unit that runs `named-checkconf`
and exits, so a bad config fails the boot visibly rather than inside a log.

`Containerfile.dns` copies `modules/dns/` onto `/` and runs every script in
`/usr/libexec/ultus-corp/build.d/` in name order with `bash`, failing the build
on the first non-zero exit.

- [ ] **Step 4: Record the resolved package set**

Run: `bash tests/test-packages.sh`, then
`podman run --rm "$(lab_image dns)" rpm -qa --qf '%{NAME}-%{EVR}.%{ARCH}\n' | sort > manifests/resolved-dns.lock`.
Expected: the test passes and the lock file lists real NEVRAs from Stream 10.
This is the empirical package check the design owes; record the commands and
the date in `docs/runbooks/packages.md`.

- [ ] **Step 5: Commit**

```bash
git add manifests modules Containerfile.dns tests/test-packages.sh docs/runbooks/packages.md
git commit -m "feat: dns role with resolved package lock"
```

---

### Task 4: The scenario spec and the renderer

**Files:**
- Create: `lab/lab.toml`
- Create: `lab/render.py`
- Create: `lab/schema.md`
- Create: `tests/test_render.py`

**Interfaces:**
- Produces: `render.py` CLI `render.py --scenario <id> --out <dir>` writing
  `<out>/<node>.xml`, `<out>/<node>-seed.iso` and `<out>/plan.json`.
- Produces: `load(path) -> dict`, `nodes_for(spec: dict, scenario: str) -> list[dict]`,
  `domain_xml(node: dict, spec: dict) -> str`.
- Produces: naming contract `ultus-<scenario>-<node>` for domains, volumes and
  networks. Later tasks depend on this prefix.

- [ ] **Step 1: Write the failing test**

`tests/test_render.py` uses `unittest` and asserts:

```python
spec = load("lab/lab.toml")
assert [n["name"] for n in nodes_for(spec, "s1-dns")] == ["dns-a", "dns-b"]
xml = domain_xml(nodes_for(spec, "s1-dns")[0], spec)
assert "ultus-s1-dns-dns-a" in xml
assert "<forward" not in xml
assert "<dhcp" not in xml
assert "<mac address=" in xml
assert nodes_for(spec, "s0-base")[0]["name"] != nodes_for(spec, "s1-dns")[0]["name"]
with self.assertRaises(ValueError):
    nodes_for(spec, "nope")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest tests.test_render -v`
Expected: FAIL, `ModuleNotFoundError: lab.render`.

- [ ] **Step 3: Implement the spec and renderer**

`lab/lab.toml` shape:

```toml
[lab]
realm = "LAB.INTERNAL"
domain = "lab.internal"
overlay = "10.255.0.0/16"

[[site]]
id = "br1"
prefix = "10.11.0.0/16"

[[scenario]]
id = "s1-dns"
title = "authoritative plus recursive"
vm_budget = 2
ram_budget_mib = 3072

[[node]]
scenario = "s1-dns"
name = "dns-a"
site = "br1"
role = "dns"
vcpus = 1
ram_mib = 1024
disk_gib = 8
addresses = ["10.11.10.11"]
gateway = "10.11.10.1"
```

`render.py` parses with `tomllib`, validates that every `[[node]]` names a
declared scenario and site, and refuses an unknown scenario with `ValueError`
naming the id. `domain_xml` uses one `<interface type='network'>` per segment
and a fixed `<mac address>` derived from `hashlib.sha256(f"{scenario}-{name}")`
with the locally administered bit set, so MACs are stable and never collide
across scenarios.

`domain_xml` must not emit `<dhcp>`, and the network XML `render.py` writes is
an `<ip>` element with no `<dhcp>` child, so libvirt runs no dnsmasq.

The seed ISO is built by writing `user-data` and `meta-data` to a temp dir and
calling `xorriso -as mkisofs -volid cidata -joliet -rock`, falling back to
`genisoimage` when `xorriso` is absent. No `cloud-utils` dependency.

`lab/schema.md` documents every key with its type and its default.

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest tests.test_render -v`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add lab tests/test_render.py
git commit -m "feat: lab.toml spec and libvirt renderer"
```

---

### Task 5: The `lab` CLI, state tracking, and the teardown gate

**Files:**
- Create: `lab/lab`
- Create: `tests/test-lab.sh`

**Interfaces:**
- Consumes: `render.py` from Task 4.
- Produces: `lab up <scenario>`, `lab down <scenario>`, `lab status`,
  `lab test <scenario>`, `lab doctor`, `lab egress on|off`.
- Produces: `run/<scenario>/state.json` listing every created object by name.

- [ ] **Step 1: Write the failing test**

`tests/test-lab.sh` uses a fake `virsh` on `PATH` that records its calls, and
asserts:

```bash
assert_ok    "doctor runs"              lab doctor
assert_fails "down before up is an error" lab down s0-base
assert_ok    "up records state"         lab up s0-base
assert_ok    "up is idempotent"         lab up s0-base
assert_ok    "status lists the scenario" lab status
assert_ok    "down removes state"       lab down s0-base
assert_fails "second down is an error"  lab down s0-base
assert_ok    "up after down succeeds"   lab up s0-base
```

Plus a partial-state case: delete `run/s0-base/state.json` while the fake
`virsh` still reports the domain, then assert `lab down s0-base` removes what
it can infer from the namespacing contract and prints a warning.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-lab.sh`
Expected: FAIL, `lab: No such file or directory`.

- [ ] **Step 3: Implement the CLI**

`lab` is a Python 3 script with no third-party imports. `up` renders, creates
the network, then the volume, then the domain, appending each name to
`state.json` as it is created. On any exception it runs the same teardown path
before exiting non-zero, so a failed `up` never leaves partial state. `down`
reads `state.json`, removes in reverse order, and when the file is missing
infers names from the `ultus-<scenario>-` prefix. `doctor` checks `/dev/kvm`,
`virsh`, `qemu-img`, `xorriso` or `genisoimage`, and free disk against the
scenario budget.

`lab egress on` adds a NAT network and a route for the hub only, and refuses on
any scenario without a `hub` profile node.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-lab.sh`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add lab tests/test-lab.sh
git commit -m "feat: lab CLI with recorded state and symmetric teardown"
```

---

### Task 6: Boot a guest, the `s0-base` scenario

**Files:**
- Create: `lab/build-disk.sh`
- Create: `tests/scenarios/s0-base.sh`
- Modify: `lab/lab.toml` (add the `s0-base` node)
- Create: `docs/runbooks/first-boot.md`

**Interfaces:**
- Consumes: `lab up|down|status` from Task 5, `lab_image` from Task 2.
- Produces: `lab/build-disk.sh <role> <out.qcow2>` using
  `quay.io/centos-bootc/bootc-image-builder`, and the first proven boot.

- [ ] **Step 1: Write the failing test**

`tests/scenarios/s0-base.sh`:

```bash
lab up s0-base
addr=$(python3 -c 'import json;print(json.load(open("run/s0-base/state.json"))["nodes"]["dns-a"]["address"])')
assert_ok "domain running"   virsh domstate ultus-s0-base-dns-a
assert_ok "guest reachable"  timeout 120 bash -c "until ping -c1 -W1 $addr; do sleep 2; done"
assert_ok "named answers"    dig +short +time=2 @$addr dns-br1.lab.internal
lab down s0-base
assert_ok "no domain left"   bash -c "! virsh list --all --name | grep -q ultus-s0-base"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/scenarios/s0-base.sh`
Expected: FAIL at `domain running`, because no disk exists yet.

- [ ] **Step 3: Build the disk and boot it**

`lab/build-disk.sh` runs the pinned builder already proven in `dux-atomic`:

```
podman run --rm --privileged --security-opt label=type:unconfined_t \
  -v "$PWD/build/vm:/output" -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder@sha256:a0ee98db5bfb8337e45efb92f0c5d1a19179c85ce80a3360abc628fd1a17cc5c \
  --type qcow2 --config build/vm/config.toml "$(lab_image "$role")"
```

`config.toml` pins the root filesystem to `xfs` and sets
`[[customizations.user]]` to the operator key from
`lab-secrets/id_ed25519.pub`, read at build time and never committed. `lab up`
regenerates the overlay qcow2 from the base image each run, so the base is
shared and growth is thin.

Add the `s0-base` node to `lab.toml` with `role = "dns"`, one address in the
`br1` management segment, and no second network.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/scenarios/s0-base.sh`
Expected: all `ok`, and `virsh list --all` shows nothing after teardown.

- [ ] **Step 5: Commit**

```bash
git add lab/build-disk.sh lab/lab.toml tests/scenarios/s0-base.sh docs/runbooks/first-boot.md
git commit -m "feat: s0-base boots a bootc guest and serves a lookup"
```

---

### Task 7: The `s1-dns` scenario, delegation and failover

**Files:**
- Create: `tests/scenarios/s1-dns.sh`
- Modify: `lab/lab.toml` (two `s1-dns` nodes)
- Create: `modules/dns/var/named/lab.internal.zone`

**Interfaces:**
- Consumes: everything from Task 6.
- Produces: a primary and a secondary that both answer, and a delegation stub
  for `ipa.lab.internal` that later identity work relies on.

- [ ] **Step 1: Write the failing test**

`tests/scenarios/s1-dns.sh` asserts: both nodes answer
`dns-br1.lab.internal`; the secondary answers after the primary is suspended
with `virsh suspend`; `dig +norec` to the primary returns `aa` for
`lab.internal`; and `dig SOA ipa.lab.internal` returns the delegation record.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/scenarios/s1-dns.sh`
Expected: FAIL, `dns-b` does not answer, because only one node is defined.

- [ ] **Step 3: Add the second node and the delegation**

`lab.toml` gains `dns-b` in the `br1` management segment with `role = "dns"`
and a `secondary_of` key naming `dns-a`. The renderer passes that to the seed
as a file, and `50-dns.sh` writes `also-notify` and `allow-transfer` from it.

The zone file carries an `NS` delegation to `ipa.lab.internal` with an `A`
record for the future FreeIPA host. The record exists before the host does, so
the delegation is proven independently of the identity work.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/scenarios/s1-dns.sh`, then `lab down s1-dns`.
Expected: all `ok`, and the teardown check passes.

- [ ] **Step 5: Commit**

```bash
git add lab/lab.toml modules/dns/var/named/lab.internal.zone tests/scenarios/s1-dns.sh
git commit -m "feat: s1-dns primary, secondary and delegation"
```

---

### Task 8: CI, supply chain, and the repin workflow

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/repin-base.yml`
- Create: `.github/dependabot.yml`
- Create: `tests/test-ci.sh`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `tests/test-static.sh`, `tests/test-image.sh`, `tests/test-packages.sh`, `tests/test_render.py`, `tests/test-lab.sh`.
- Produces: a CI gate that fails on any of those, and a weekly digest bump PR.

- [ ] **Step 1: Write the failing check**

`tests/test-ci.sh` asserts `ci.yml` names every gate script, runs
`cosign sign` with `id-token: write`, and runs `trivy image` before signing.
Run it: `bash tests/test-ci.sh` fails, no workflow file.

- [ ] **Step 2: Write the workflows**

`ci.yml` jobs: `static` (Task 1), `matrix` over `[dns]` for build plus
`tests/test-packages.sh`, `render` (Task 4), `lab` (Task 5 with a fake virsh),
`supply` (syft SBOM, trivy with `--exit-code 1 --severity CRITICAL`, cosign
keyless). `repin-base.yml` runs weekly, resolves the `stream10` tag to a
digest, opens a PR that edits `manifests/base.txt` only, and fails when the new
digest is unsigned.

- [ ] **Step 3: Run the checks**

Run: `bash tests/test-ci.sh` and `bash tests/test-static.sh`.
Expected: both pass, and `actionlint` reports no error when installed.

- [ ] **Step 4: Commit**

```bash
git add .github tests/test-ci.sh CHANGELOG.md
git commit -m "feat: CI gates, keyless signing and weekly base repin"
```

---

### Task 9: Isolation gate, runbooks, and the phase close

**Files:**
- Create: `tests/test-isolation.sh`
- Create: `docs/runbooks/scenarios.md`, `docs/runbooks/isolation.md`
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `lab doctor`, `lab status`.
- Produces: the gate that makes the public repo safe to publish.

- [ ] **Step 1: Write the failing test**

`tests/test-isolation.sh` asserts: every defined libvirt network has no
`<forward mode='bridge|route|passthrough'>` and no `<bridge name=...>`; every
lab CIDR in `lab.toml` is disjoint from every CIDR in `ip -j route show`; and
no lab range equals the host's own.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-isolation.sh`
Expected: FAIL. The check must report "no networks defined" as a failure rather
than pass vacuously.

- [ ] **Step 3: Implement the gate and the runbooks**

The gate reads `virsh net-dumpxml` for every network matching `ultus-`, and
`lab doctor` gains a `--host-routes` mode that prints parsed host CIDRs for the
test to compare. `docs/runbooks/scenarios.md` documents the one-scenario
contract, the ten-minute rebuild rule and the teardown expectation.
`docs/runbooks/isolation.md` documents why no bridge exists and what to check
before publishing.

- [ ] **Step 4: Run the full gate set**

Run: `bash tests/test-static.sh && python3 -m unittest tests.test_render -v && bash tests/test-lab.sh && bash tests/test-ci.sh && bash tests/test-isolation.sh`
Expected: every gate passes, and the command line is recorded in
`docs/runbooks/scenarios.md` as the P0 acceptance line.

- [ ] **Step 5: Commit**

```bash
git add tests/test-isolation.sh docs README.md CHANGELOG.md
git commit -m "feat: isolation gate and P0 runbooks"
```

---

## Self-Review

**Spec coverage.** P0 and s0-base come from the design's Scenarios table. The
static, build, image, scenario, teardown, supply-chain and isolation gates are
Tasks 1, 2, 3, 6, 5, 8 and 9. The scenario model's five rules are covered by
Tasks 4 and 5. Not in this plan, by design: s2 and later scenarios, assembly
runs, identity, endpoints and stateful roles. Each becomes its own plan, in the
design's scenario order, because each is an independent subsystem.

**Step scan.** Every step names a file, a command and an expected result. The
renderer step states the MAC derivation and the no-dnsmasq rule because a
signature cannot carry them.

**Type consistency.** `build_role`, `lab_image`, `load`, `nodes_for` and
`domain_xml` keep one signature across Tasks 2, 3, 4, 5 and 6. The domain name
contract `ultus-<scenario>-<node>` is stated once in Task 4 and reused verbatim
in Tasks 5, 6, 7 and 9.

**Review Focus.** Six risks, each with a test: partial state (Task 5), name
collision (Tasks 4 and 5), host overlap (Task 9), missing package (Task 3),
stale seed key (Tasks 4 and 6), libvirt dnsmasq (Task 4).

**Proportion.** Nine tasks for two scenarios plus the harness. The code blocks
are fixtures, assertions and one image reference, not implementation bodies.

## Plan sequence after this one

| Plan | Scenarios | Why it is separate |
| --- | --- | --- |
| 1, this plan | s0, s1 | Harness plus the first service |
| 2 | s2, s3 | Packet path: relay, routing, policy, overlay |
| 3 | s4, s5 | Trust and identity |
| 4 | s6, s9 | 802.1X and endpoint onboarding |
| 5 | s7, s8 | Delivery and observability |
| 6 | s10, assembly | Stateful roles, then the assembly gates |
