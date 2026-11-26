# P0 Scenario Harness and the DNS Scenario: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the repo skeleton, the scenario harness, and the first two runnable scenarios (`s0-base` and `s1-dns`) so every later role inherits a working build, boot, test and teardown cycle.

**Architecture:** One `Containerfile.<role>` per role, all `FROM` one digest-pinned CentOS Stream 10 bootc base passed as a build argument. A stdlib-only Python renderer turns `lab/lab.toml` into libvirt network and domain XML plus a NoCloud seed ISO. A single `lab` CLI runs one scenario at a time, records everything it creates in a typed state file, and records what each assertion observed.

**Tech Stack:** CentOS Stream 10 image mode, bootc, Podman, image-builder, BIND 9, Unbound, libvirt/KVM, Python 3.11+ stdlib (`tomllib`, `dataclasses`, `ipaddress`), bash test harness.

**Spec:** `docs/superpowers/specs/2026-11-26-ultus-corp-design.md`

## Global Constraints

- Base image: `quay.io/centos-bootc/centos-bootc:stream10@sha256:0df2ed8fd881b36b34f559c59eb5c4a51992f69b1ce05203307ce29ed1a76f87`, tag and digest both present.
- Guests are CentOS Stream 10 only. No Fedora, Ubuntu or Debian guest.
- P0 builds the primary DC hub and the branches. The DR DC is evolution stage 3 in the design and is not a P0 scenario.
- One scenario resident at a time. A single scenario stays below five VMs and at most 10 GiB RAM.
- `lab down` leaves no domain, network, volume or generated key, and a second `lab up` succeeds.
- No libvirt network may forward to the host LAN. libvirt has no `isolated` forward mode, so a rendered network omits `<forward>` entirely, which is what makes it isolated. It carries no DHCP and no libvirt DNS.
- Secrets never enter git, an image, or a rendered file inside the tree. `lab-secrets/` is gitignored, runtime material lives under `run/` with mode `0700`.
- Renderer uses the Python standard library only. No PyYAML, no external YAML parser.
- Every role `FROM` the base in `manifests/base.txt`, passed as `--build-arg BASE=…`.
- `greenboot` is in the common manifest, and every role ships a required health check under `/etc/greenboot/check/required.d/`.
- Every role carries `docs/roles/<role>.md` with four fields: Linux mechanism, closest Windows concept, where the analogy breaks, and the proving command.
- Repo is public, MIT, generic. No client name and no real address.
- Commit subjects use `feat:`/`fix:`/`chore:`/`docs:`/`test:` and one logical change per commit.

## Platform evidence

Facts this plan depends on, read 2026-11-26. The design's table is the full
record. A failing fact here is a plan bug.

| Fact | Value |
| --- | --- |
| Base image | `centos-bootc:stream10` multi-arch, digest `0df2ed8f…` |
| Kea | `3.0.3-1.el10`, BaseOS |
| greenboot | `0.16.5-0.el10`, AppStream |
| hostapd | `2.11-2.el10`, AppStream |
| ipa-server-dns | `4.13.4-1.el10`, AppStream |
| Image to disk | `image-builder build --bootc-ref … qcow2` |
| Host, measured | 12 threads, 30 GiB RAM, 56 GiB free, python3.14 |
| Host, missing | `virsh`, `xorriso`, `genisoimage`, `dig` |

## Prerequisites the operator installs once

The host tools are not repo artifacts. Install them before Task 6:

```bash
sudo pacman -S --needed libvirt qemu-full edk2-ovmf libisoburn dnsutils
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER"
```

`lab doctor` fails with the exact missing package name, so a fresh host gets a
named next step rather than a stack trace. Task 5's tests use a fake `virsh`
and need none of this. Task 6 is the first task that does.

`bootc-image-builder` refuses rootless podman, and the disk build mounts loop
devices, so that one step runs as root. `lab/build-disk.sh` builds through
`${LAB_PODMAN:-podman}` and names the fix when it finds rootless podman:

```bash
LAB_PODMAN='sudo podman' lab up s0-base
```

The built qcow2 is cached under `build/vm/cache/<role>-<image-id>.qcow2`, so the
privileged step runs once per image rather than once per VM. On a cache miss the
script copies the image into the build storage unconditionally, then asserts the
id it landed on. A tag can exist there and still point at an older image, and a
builder given that tag emits a disk with none of the current module code. The
assertion turns that into a failed build instead of a disk that boots and
fails at provisioning.

## Review Focus

- A failed `lab up` leaves half its objects behind. Expectation: teardown runs from recorded state, and a teardown that cannot finish keeps its state and exits non-zero.
- Two scenarios pick the same libvirt network or volume name. Expectation: names are scenario-scoped, so both can exist sequentially.
- The host's own address space overlaps a lab prefix. Expectation: the isolation gate fails on the rendered definition, before boot.
- A role package is absent from Stream 10, or resolves to a different NEVRA than the lock. Expectation: the build fails on the package, not at boot.
- libvirt's own dnsmasq answers a lookup. Expectation: the network XML disables libvirt DNS, and a negative control query proves it.
- A seed is reused with a stale key or stale address. Expectation: each `up` writes a fresh seed from the spec and removes it on `down`.
- A test prints `ok` without saying what it saw. Expectation: no assertion may pass without a recorded observation.

---

### Task 1: Repository skeleton, the evidence recorder and the static gate

**Files:**
- Create: `README.md`, `LICENSE`, `CHANGELOG.md`
- Modify: `.gitignore` (it exists; keep every entry and add the ones listed below)
- Create: `build/checks.sh`
- Create: `tests/lib.sh`, `tests/test-static.sh`
- Create: `tests/fixtures/base.expected`
- Create: `tests/fixtures/Containerfile.pinned`, `tests/fixtures/Containerfile.wrong-repo`
- Create: `tests/fixtures/packages-multi.txt`, `tests/fixtures/packages-ok.txt`
- Create: `tests/fixtures/leak-key.txt`, `tests/fixtures/leak-clean.txt`, `tests/fixtures/leak-disc.iso`
- Create: `tests/fixtures/roles/dns.md`, `tests/fixtures/roles/incomplete.md`

**Interfaces:**
- Produces: `build/checks.sh` pure functions, each returning 0 when the tree is clean and 1 with a one-line reason on stdout:
  - `check_base_pin <expected-file> <file>...` compares the effective `FROM` value against the expected reference, not merely its shape.
  - `check_manifest_one_per_line <file>...`
  - `check_no_secret_patterns <dir>`
  - `check_no_install_media <dir>`
  - `check_role_records <roles-dir|file>...`
- Produces: `tests/lib.sh` with `assert_ok`, `assert_fails`, `assert_eq`, and `record`. Every assertion appends one line to `run/evidence/<gate>.log`, where `<gate>` is the test script's name without `test-` and `.sh`: `run/evidence/static.log` for `tests/test-static.sh`. The line holds name, status, command, expected, observed.

- [ ] **Step 1: Write the failing test**

`tests/test-static.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh

assert_ok    "pinned base accepted"   check_base_pin tests/fixtures/base.expected tests/fixtures/Containerfile.pinned
assert_fails "wrong repository rejected" check_base_pin tests/fixtures/base.expected tests/fixtures/Containerfile.wrong-repo
assert_ok    "one package per line accepted"      check_manifest_one_per_line tests/fixtures/packages-ok.txt
assert_fails "two packages on one line rejected"  check_manifest_one_per_line tests/fixtures/packages-multi.txt
assert_fails "key material in tree rejected"      check_no_secret_patterns tests/fixtures
assert_ok    "clean file accepted"                check_no_secret_patterns tests/fixtures/leak-clean.txt
assert_fails "install media rejected"             check_no_install_media tests/fixtures
assert_ok    "complete role record accepted"      check_role_records tests/fixtures/roles/dns.md
assert_fails "incomplete role record rejected"    check_role_records tests/fixtures/roles/incomplete.md

finish
```

`finish` lives in `tests/lib.sh`: it prints the failing count, exits 1 when
`FAILURES` is non-zero, and otherwise prints `static gate passed` plus the
evidence path.

Fixture contents: `base.expected` holds the pinned reference from Global
Constraints. `Containerfile.pinned` has `FROM <that reference>`.
`Containerfile.wrong-repo` has the same tag and digest under
`docker.io/library/centos`. `packages-multi.txt` has one line with
`bind unbound`. `packages-ok.txt` has one package per line. `leak-key.txt`
holds a private-key armour banner spelled with spaces. `leak-disc.iso` is a
one-byte file with an `.iso` name. `roles/dns.md` has all four fields.
`roles/incomplete.md` has three.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-static.sh`
Expected: FAIL, `build/checks.sh: No such file or directory`.

- [ ] **Step 3: Implement the checks and the recorder**

`check_base_pin` reads the expected reference from `$1`, extracts the value of
the last `FROM` line in each remaining file, expands `${BASE}` when the file
declares `ARG BASE=<value>`, and compares exact strings. `FROM scratch` is
skipped.

`check_manifest_one_per_line` rejects any non-comment line with whitespace
after trimming. `check_no_secret_patterns` greps for the private-key armour
banner, an age secret-key prefix, a `WireGuard` `PrivateKey =` line, and a
`lab-secrets/` path outside `.gitignore`. `check_no_install_media` rejects
`*.iso`, `*.vhd`, `*.qcow2` and `*.wim` outside `run/`.
`check_role_records` requires each `docs/roles/<role>.md` to contain the four
headings `## Linux mechanism`, `## Windows concept`, `## Where it breaks`,
`## Proof`, and fails for a role directory in `modules/` with no record.

`tests/lib.sh`:

```bash
FAILURES=0
_name=${0##*/}; _name=${_name%.sh}; _name=${_name#test-}
EVIDENCE=${EVIDENCE:-run/evidence/$_name.log}
mkdir -p "$(dirname "$EVIDENCE")"
. build/checks.sh

record() {
  local name=$1 status=$2 expected=$3 observed=$4
  shift 4
  printf '%s|%s|%s|%s|%s\n' "$name" "$status" "$*" "$expected" "$observed" >> "$EVIDENCE"
}

assert_ok() {
  local name=$1; shift
  local out status
  out=$("$@" 2>&1) && status=ok || status=fail
  record "$name" "$status" "exit 0" "${out:-no output}" "$@"
  if [ "$status" = ok ]; then echo "ok $name"; else echo "FAIL $name: ${out:-exit $?}"; FAILURES=$((FAILURES+1)); fi
}

assert_fails() {
  local name=$1; shift
  local out status
  out=$("$@" 2>&1) && status=ok || status=fail
  record "$name" "$status" "non-zero exit" "${out:-no output}" "$@"
  if [ "$status" = ok ]; then echo "FAIL $name: exited 0"; FAILURES=$((FAILURES+1)); else echo "ok $name (refused: ${out%%$'\n'*})"; fi
}

assert_eq() {
  local name=$1 expected=$2 observed=$3
  record "$name" "$([ "$expected" = "$observed" ] && echo ok || echo fail)" "$expected" "$observed" "compare"
  if [ "$expected" = "$observed" ]; then echo "ok $name"; else echo "FAIL $name: expected '$expected', observed '$observed'"; FAILURES=$((FAILURES+1)); fi
}

finish() {
  if [ "$FAILURES" -ne 0 ]; then echo "$FAILURES failing"; exit 1; fi
  echo "static gate passed"
  echo "evidence: $EVIDENCE"
}
```

Modify `.gitignore`: keep `run/`, `build/vm/`, `build/out/`, `lab-secrets/`,
`*.qcow2`, `*.iso`, `*.wim`, `.venv/`, `__pycache__/`, and add
`run/evidence/` so recorded output is never committed.

Create `README.md` with the spec link, a status line and a pointer to
`docs/runbooks/`. Create `LICENSE` with MIT text and `CHANGELOG.md` with
`## Unreleased` and one entry naming this plan.

`.gitignore` excludes `*.iso`, so the media fixture needs
`git add -f tests/fixtures/leak-disc.iso`. Without the force-add the fixture is
absent after a fresh clone and that assertion passes vacuously.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-static.sh`
Expected: `static gate passed`, and `run/evidence/static.log` has nine lines,
each with a non-empty observed field.

- [ ] **Step 5: Commit**

```bash
git add README.md LICENSE CHANGELOG.md .gitignore build/checks.sh tests/
git commit -m "feat: repo skeleton, evidence recorder and static gate"
```

---

### Task 2: Base pin, build argument, and the first image build

**Files:**
- Create: `manifests/base.txt`, `manifests/packages-common.txt`
- Create: `build/common.sh`, `build/manifest.sh`, `build/package-lock.sh`
- Create: `Containerfile.dns`
- Create: `modules/base/usr/libexec/ultus-corp/build.d/00-base.sh`
- Create: `tests/test-image.sh`

**Interfaces:**
- Consumes: `check_base_pin` from Task 1.
- Produces: `base_ref` printing `manifests/base.txt`, and `build_role <role>` building
  `localhost/ultus-corp/<role>:local` with `--build-arg BASE="$(base_ref)"`, then
  running `bootc container lint`.
- Produces: `build/package-lock.sh resolve <role>` writing
  `manifests/packages-<role>.lock`, one `name-evr.arch` per line.
- Produces: `lab_image <role>` printing `localhost/ultus-corp/<role>:local`.

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
assert_ok "greenboot installed" \
  podman run --rm "$(lab_image "$role")" rpm -q greenboot
assert_ok "base is CentOS Stream 10" \
  podman run --rm "$(lab_image "$role")" grep -q '^VERSION_ID="10"' /etc/os-release
assert_ok "renderer sees tomllib" \
  python3 -c 'import tomllib'

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-image.sh dns`
Expected: FAIL, `Containerfile.dns: no such file or directory`.

- [ ] **Step 3: Write the base pin, manifests and build scripts**

`manifests/base.txt` holds exactly one line, the pinned reference from Global
Constraints. `build/manifest.sh` joins `manifests/packages-common.txt` with
`manifests/packages-<role>.txt`, sorts and de-duplicates into
`build/out/packages-<role>.txt`.

`manifests/packages-common.txt`, one per line: `cloud-init`,
`openssh-server`, `qemu-guest-agent`, `sudo`, `podman`, `nftables`,
`policycoreutils`, `selinux-policy-targeted`, `chrony`, `greenboot`.

`build/common.sh`:

```bash
base_ref() { head -1 manifests/base.txt; }
lab_image() { echo "localhost/ultus-corp/$1:local"; }

build_role() {
  local role=$1
  podman pull -q "$(base_ref)" || return 1
  podman build --build-arg BASE="$(base_ref)" -f "Containerfile.$role" \
    -t "$(lab_image "$role")" . || return 1
  podman run --rm "$(lab_image "$role")" bootc container lint
}
```

`Containerfile.dns` starts with `ARG BASE`, then `FROM ${BASE}`, bind-mounts
`build/out/install-<role>.txt` (the lock when one exists, the joined manifest
otherwise), installs from it, cleans the dnf cache, copies `modules/base/` onto
`/`, and runs `/usr/libexec/ultus-corp/build.d/` in name order. The lint runs
from the build script so it runs on a cached build.

`modules/` must exist before the first build, or the bind-mount has no source.
Task 2 therefore creates
`modules/base/usr/libexec/ultus-corp/build.d/00-base.sh`, which asserts the base
contract the other modules rely on: `bootc` and `greenboot` are installed and
the bootc unit is present. It also enables `greenboot-healthcheck.service`: the
package ships it disabled, and a required check that never runs proves nothing.
`COPY modules/base/ /` copies the tree's contents onto `/`. Task 3 adds
`COPY modules/dns/ /` beside it.

`build/package-lock.sh resolve <role>` builds the image, then writes
`podman run --rm "$(lab_image "$role")" rpm -qa --qf '%{NAME}-%{EVR}.%{ARCH}\n' | grep -v '^gpg-pubkey-' | sort`
to the lock file. The filter matters: `rpm -qa` lists `gpg-pubkey` pseudo-packages
but `dnf install` cannot resolve them, so an unfiltered lock breaks the next
build. When a lock exists, `Containerfile.<role>` installs `$(cat /tmp/packages.lock)`
so the NEVRAs are pinned.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-image.sh dns`
Expected: five `ok` lines including `renderer sees tomllib`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add manifests build Containerfile.dns tests/test-image.sh
git commit -m "feat: pinned base, build argument and first role image"
```

---

### Task 3: The dns role, the package lock, and the health check

**Files:**
- Create: `manifests/packages-dns.txt`
- Modify: `Containerfile.dns` (add `COPY modules/dns/ /`)
- Create: `modules/dns/usr/libexec/ultus-corp/build.d/50-dns.sh`
- Create: `modules/dns/usr/libexec/ultus-corp/provision.sh`
- Create: `modules/dns/etc/named.conf`, `modules/dns/etc/unbound/unbound.conf`
- Create: `modules/dns/var/named/lab.internal.zone`
- Create: `modules/dns/usr/lib/systemd/system/ultus-provision.service`
- Create: `modules/dns/usr/lib/systemd/system/ultus-dns-ready.service`
- Create: `modules/dns/etc/greenboot/check/required.d/50-dns-health.sh`
- Create: `docs/roles/dns.md`
- Create: `tests/test-packages.sh`

**Interfaces:**
- Consumes: `build_role`, `lab_image`, `build/package-lock.sh` from Task 2.
- Produces: a `dns` image whose node-specific config is rendered at boot from
  `/run/ultus-corp/node.json`, and whose zone file already exists at build time.

- [ ] **Step 1: Write the failing test**

`tests/test-packages.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/common.sh
img=$(lab_image dns)

run_role_proof() {
  local role=$1 proof
  proof=$(sed -n '/^```proof$/,/^```$/p' "docs/roles/$role.md" | sed '1d;$d')
  [ -n "$proof" ] || { echo "no proof block in docs/roles/$role.md"; return 1; }
  podman run --rm "$(lab_image "$role")" bash -c "$proof"
}

assert_ok "bind installed"        podman run --rm "$img" rpm -q bind
assert_ok "unbound installed"     podman run --rm "$img" rpm -q unbound
assert_ok "zone file present"     podman run --rm "$img" test -s /var/named/lab.internal.zone
assert_ok "named config valid"    podman run --rm "$img" named-checkconf -z /etc/named.conf
assert_ok "unbound config valid"  podman run --rm "$img" unbound-checkconf /etc/unbound/unbound.conf
assert_ok "provision unit enabled" podman run --rm "$img" systemctl is-enabled ultus-provision.service
assert_ok "health check executable" \
  podman run --rm "$img" test -x /etc/greenboot/check/required.d/50-dns-health.sh
assert_ok "record proof passes"   run_role_proof dns

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-packages.sh`
Expected: FAIL, `bind installed: package bind is not installed`.

- [ ] **Step 3: Add the role**

`manifests/packages-dns.txt`, one per line: `bind`, `bind-utils`, `unbound`.

`50-dns.sh` runs `systemctl enable ultus-provision.service ultus-dns-ready.service`
and asserts both are enabled, exiting non-zero with the unit name on failure.

`lab.internal.zone` is created here, not in a later task: a primary with `SOA`,
`NS`, and one placeholder `A` record for `dns-a` on `127.0.0.2`. The placeholder
is what makes `named-checkconf -z` load the zone at build time, because `BIND`
refuses an `NS` target with no address. `provision.sh` rewrites the owner name
and the address to the booted node's own, so no run's address is baked into an
image. `named.conf` serves the zone from `/var/named/lab.internal.zone` and
forwards nothing. `unbound.conf` listens on loopback and forwards
`lab.internal` to `127.0.0.2`. Both are the single-node default, valid at
build time.

`provision.sh` reads `/run/ultus-corp/node.json` and specialises that default:
it rewrites the listen address, the forwarder, and the zone's owner name and
address. When the node carries a `secondary` field it writes a `type secondary`
stanza with `masters` and `allow-transfer` instead of the primary stanza. It
then runs `named-checkconf`. It is the only place node-specific configuration is
produced, because build time cannot see the seed. The rewrite is idempotent.

The owner-name rewrite matches the bare token `dns-a`, not a dotted FQDN. The
`A` record owner is written without a trailing dot, so a `dns-a\.` pattern
renames `SOA` and `NS` but leaves the `A` owner behind, and `named-checkconf -z`
then rejects an `NS` target with no address.

`50-dns.sh` enables `unbound.service` alongside the two ultus units. Nothing
else pulls it, and the required check queries `127.0.0.1`, so an unenabled
resolver turns a healthy node into a failed boot.

`ultus-provision.service` is `Type=oneshot`, `RemainAfterExit=yes`, ordered
`Before=named.service`, and runs `provision.sh` as root.

`ultus-dns-ready.service` runs `named-checkconf -z` and is enabled, so a bad
zone fails the boot visibly rather than inside a log.

`50-dns-health.sh` queries `127.0.0.1` for `lab.internal SOA` and exits
non-zero with the dig output when the answer is empty. It sits in `required.d`,
so a dns image that boots but cannot answer rolls back.

`docs/roles/dns.md` carries the four headings and one fenced `proof` block
holding `named-checkconf -z /etc/named.conf`. `run_role_proof` extracts that
block and runs it in the image, so the record is executed rather than read.

- [ ] **Step 4: Record the resolved package set**

Run the build first, because `tests/test-packages.sh` asserts against an image
and does not build one. `build/package-lock.sh resolve dns` builds from the
manifest and writes the lock, so it produces both:

```bash
bash build/package-lock.sh resolve dns
bash tests/test-packages.sh
```

Expected: the test passes and `manifests/packages-dns.lock` lists real NEVRAs
from Stream 10. Rebuild with the lock present, then prove the lock is what got
installed:

```bash
. build/common.sh && build_role dns
podman run --rm localhost/ultus-corp/dns:local rpm -qa --qf '%{NAME}-%{EVR}.%{ARCH}\n' \
  | grep -v '^gpg-pubkey-' | sort > run/dns-installed.txt
diff run/dns-installed.txt manifests/packages-dns.lock
```

Expected: no output. Record the commands and the date in
`docs/runbooks/packages.md`.

- [ ] **Step 5: Commit**

```bash
git add manifests modules Containerfile.dns docs/roles docs/runbooks/packages.md tests/test-packages.sh
git commit -m "feat: dns role with zone, boot provisioning and package lock"
```

---

### Task 4: The scenario spec and the renderer

**Files:**
- Create: `lab/lab.toml`
- Create: `lab/render.py`
- Create: `lab/schema.md`
- Create: `tests/test_render.py`
- Create: `tests/fixtures/lab-unknown-key.toml`

**Interfaces:**
- Produces: `render.py --scenario <id> --out <dir>` writing
  `<out>/<scenario>-<segment>.network.xml`, `<out>/<node>.xml`,
  `<out>/<node>-seed/{meta-data,user-data,network-config}` and `<out>/plan.json`.
  The ISO is built later, by `lab up`, so the renderer never needs an ISO writer.
- Produces: `load(path) -> Spec` returning validated dataclasses, and
  `nodes_for(spec, scenario) -> list[Node]`,
  `network_xml(scenario_id, segment, spec) -> str`,
  `domain_xml(node, spec) -> str`, `seed_files(node, spec) -> dict[str, str]`.
- Produces: naming contract `ultus-<scenario>-<node>` for domains and volumes,
  `ultus-<scenario>-<segment>` for networks.

- [ ] **Step 1: Write the failing test**

`tests/test_render.py`, using `unittest`:

```python
import json

spec = load("lab/lab.toml")
self.assertEqual([n.name for n in nodes_for(spec, "s1-dns")], ["dns-a", "dns-b"])
self.assertEqual([n.name for n in nodes_for(spec, "s0-base")], ["base-a"])
self.assertEqual(nodes_for(spec, "s1-dns")[0].site, "dc")

node = nodes_for(spec, "s1-dns")[0]
xml = domain_xml(node, spec)
self.assertIn("ultus-s1-dns-dns-a", xml)
self.assertIn("<source network='ultus-s1-dns-mgmt'/>", xml)
self.assertIn("<source network='ultus-s1-dns-data'/>", xml)
self.assertNotIn("<forward", xml)

net = network_xml("s1-dns", spec.sites["dc"].segments["mgmt"], spec)
self.assertIn("ultus-s1-dns-mgmt", net)
self.assertNotIn("<forward", net)
self.assertIn("<dns enable='no'/>", net)
self.assertNotIn("<dhcp", net)
self.assertNotIn("<bridge", net)

macs = [interface_mac(s.id, n.name, i.segment) for s in spec.scenarios.values()
        for n in nodes_for(spec, s.id) for i in n.interfaces]
self.assertEqual(len(macs), len(set(macs)))
for mac in macs:
    first = int(mac.split(":")[0], 16)
    self.assertEqual(first & 0x01, 0)   # unicast: multicast bit clear
    self.assertEqual(first & 0x02, 2)   # locally administered

files = seed_files(node, spec)
self.assertIn("instance-id: ultus-s1-dns-dns-a", files["meta-data"])
network = json.loads(files["network-config"])
self.assertEqual(network["version"], 2)
self.assertIn("10.100.10.11/24", files["network-config"])

with self.assertRaises(ValueError):
    nodes_for(spec, "nope")
with self.assertRaises(ValueError):
    load("tests/fixtures/lab-unknown-key.toml")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest tests.test_render -v`
Expected: FAIL, `ModuleNotFoundError: lab.render`.

- [ ] **Step 3: Implement the spec and renderer**

`lab/lab.toml` uses nested tables:

```toml
[lab]
realm = "LAB.INTERNAL"
domain = "lab.internal"
overlay = "10.255.0.0/16"

[[site]]
id = "dc"
prefix = "10.100.0.0/16"

  [[site.segment]]
  name = "mgmt"
  cidr = "10.100.10.0/24"

  [[site.segment]]
  name = "data"
  cidr = "10.100.20.0/24"

[[scenario]]
id = "s0-base"
title = "bootable image"
vm_budget = 1
ram_budget_mib = 2048

[[scenario]]
id = "s1-dns"
title = "authoritative plus recursive"
vm_budget = 2
ram_budget_mib = 3072

[[node]]
scenario = "s0-base"
name = "base-a"
site = "dc"
role = "dns"
vcpus = 1
ram_mib = 1024
disk_gib = 8

  [[node.interface]]
  segment = "mgmt"
  address = "10.100.10.20"
  gateway = "10.100.10.1"
  nameservers = ["10.100.10.20"]

[[node]]
scenario = "s1-dns"
name = "dns-a"
site = "dc"
role = "dns"
vcpus = 1
ram_mib = 1024
disk_gib = 8

  [[node.interface]]
  segment = "mgmt"
  address = "10.100.10.11"
  gateway = "10.100.10.1"
  nameservers = ["10.100.10.11"]

  [[node.interface]]
  segment = "data"
  address = "10.100.20.11"
  gateway = "10.100.20.1"
  nameservers = ["10.100.10.11"]

[[node]]
scenario = "s1-dns"
name = "dns-b"
site = "dc"
role = "dns"
vcpus = 1
ram_mib = 1024
disk_gib = 8

  [[node.interface]]
  segment = "mgmt"
  address = "10.100.10.12"
  gateway = "10.100.10.1"
  nameservers = ["10.100.10.11"]
```

`render.py` loads with `tomllib`, converts into frozen dataclasses
(`Spec`, `Site`, `Segment`, `Scenario`, `Node`, `Interface`), and rejects:
an unknown key at any level, a duplicate id or name, an invalid CIDR, an
address outside its segment, a scenario or site that does not exist, and a
node set that exceeds its scenario's VM or RAM budget. Every failure raises
`ValueError` naming the offending key.

`interface_mac(scenario, node, segment)` hashes
`f"{scenario}-{node}-{segment}"`, sets the local bit and clears the multicast
bit: `first = (digest[0] | 0x02) & 0xfe`. The renderer then asserts the six
octets are unique across every interface in the spec.

`network_xml` emits no `<forward>` element, one `<ip address=… prefix=…>` and a
`<dns enable='no'/>` child. libvirt rejects `mode='isolated'` with "unknown
forwarding type", and the absence of `<forward>` is what isolates the network.
There is no `<dhcp>` element and no `<bridge name=…>`, so libvirt starts no
dnsmasq and no DHCP.

`seed_files` returns three strings. `meta-data` carries the scenario-scoped
instance id and the FQDN. `user-data` is `#cloud-config` followed by
`json.dumps` of a dict that writes `/run/ultus-corp/node.json` and enables
`ultus-provision.service`; JSON is a valid YAML subset, so no YAML writer is
needed. `network-config` is a version 2 dict rendered with `json.dumps`,
carrying the static address, prefix, default route and nameservers per
interface. The test parses both documents back with `json.loads`.

`lab/schema.md` documents every key, its type, its default and its rejection
rule.

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest tests.test_render -v`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add lab tests/test_render.py tests/fixtures/lab-unknown-key.toml
git commit -m "feat: typed lab.toml spec, isolated networks and NoCloud seed"
```

---

### Task 5: The `lab` CLI, typed state, and the teardown failure contract

**Files:**
- Create: `lab/lab`
- Create: `lab/state.py`
- Create: `tests/test-lab.sh`

**Interfaces:**
- Consumes: `render.py` from Task 4, and `lab/build-disk.sh` from Task 6 through
  `${LAB_DISK_BUILDER:-lab/build-disk.sh}`. Until Task 6 lands, a test sets
  `LAB_DISK_BUILDER` to a fake that writes a small file, so `up` needs no
  libvirt and no image-builder on this host.
- Produces: `lab up <scenario>`, `lab down <scenario>`, `lab status`,
  `lab test <scenario>`, `lab doctor`, `lab egress on|off`, `lab prune`.
- Produces: `run/<scenario>/state.json` with schema 1:

```json
{
  "schema": 1,
  "scenario": "s1-dns",
  "owner": "6f6c1f9e-…",
  "nodes": {"dns-a": {"address": "10.100.10.11", "domain": "ultus-s1-dns-dns-a"}},
  "resources": [
    {"kind": "network", "name": "ultus-s1-dns-mgmt"},
    {"kind": "seed", "name": "ultus-s1-dns-dns-a-seed", "mode": "0700"},
    {"kind": "volume", "name": "ultus-s1-dns-dns-a.qcow2"},
    {"kind": "domain", "name": "ultus-s1-dns-dns-a"}
  ]
}
```

- Produces: `run/<scenario>/seed/<node>/` holding `meta-data`, `user-data` and
  `network-config`, directory mode `0700`, files `0600`. The ISO is built later,
  by the disk path that Task 6 adds.

- [ ] **Step 1: Write the failing test**

`tests/test-lab.sh` puts a fake `virsh` and `qemu-img` on `PATH` that record
calls and can be told to fail on the third create. It asserts:

```bash
assert_fails "down before up is an error" lab down s0-base
assert_ok    "up records state"           lab up s0-base
assert_ok    "state is schema 1"          python3 -c 'import json,sys; d=json.load(open("run/s0-base/state.json")); sys.exit(d["schema"] != 1)'
assert_ok    "up is idempotent"           lab up s0-base
assert_ok    "status lists the scenario"  lab status
assert_ok    "seed is 0700"               bash -c '[ "$(stat -c %a run/s0-base/seed)" = 700 ]'
assert_ok    "seed file is 0600"          bash -c '[ "$(stat -c %a run/s0-base/seed/base-a/meta-data)" = 600 ]'
assert_fails "failed up exits non-zero"   bash -c 'VIRSH_FAIL_ON=3 lab up s1-dns'
assert_ok    "failed up leaves no domain" bash -c '! virsh list --all --name | grep -q ultus-s1-dns'
assert_ok    "down removes state"         lab down s0-base
assert_fails "second down is an error"    lab down s0-base
assert_ok    "up after down succeeds"     lab up s0-base
assert_ok    "prune refuses in-use disk"  bash -c 'lab up s0-base && ! lab prune --all'
```

A separate case deletes `run/s0-base/state.json` while the fake `virsh` still
reports the domain, then asserts `lab down s0-base --force` removes only the
names the spec derives for that scenario, prints a warning, and clears the state
file when nothing remains.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-lab.sh`
Expected: FAIL, `lab: No such file or directory`.

- [ ] **Step 3: Implement the CLI**

`lab` is a Python 3 script with no third-party imports. `up` runs render, then
creates network, seed, volume and domain in that order. Before the volume it
calls `${LAB_DISK_BUILDER:-lab/build-disk.sh}`, so the test substitutes a fake
and this task needs no libvirt. Each resource is appended to `state.json`
through `state.py`, which writes a temp file, fsyncs and renames, so the record
is never half-written. Node addresses come from the same spec, so `state.json`
never invents one.

The failure contract is explicit. If any create fails, `up` tears down from
recorded state. If a delete then fails, `up` keeps `state.json`, prints the
retained resources, exits 2, and names `lab down <scenario>` as the recovery
step. A cleanup that cannot finish is never reported as clean.

`down` removes in reverse order from state. With no state file it refuses,
unless `--force` is passed. `--force` first validates the id against the spec and
exits non-zero for an unknown one, so `s1` is refused before any match. It then
deletes only names the spec derives for that scenario: `ultus-<scenario>-<node>`
and `ultus-<scenario>-<segment>`. A prefix match alone would make
`ultus-s1-*` delete every `ultus-s1-dns-*` resource. When nothing remains it
clears the state file, so a later `up` is not told the scenario is already up.

`doctor` checks `/dev/kvm`, `virsh`, `qemu-img`, `xorriso` or `genisoimage`,
Python 3.11 or newer, free disk against the scenario budget, and the 20 GiB
artifact cache budget. `prune` deletes unused role caches and base disks and
refuses any file an active domain has open.

`lab egress on` adds a NAT network and a route for the hub only, and refuses on
any scenario without a `hub` profile node.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-lab.sh`
Expected: every `ok`, including the injected-failure and prune cases.

- [ ] **Step 5: Commit**

```bash
git add lab tests/test-lab.sh
git commit -m "feat: lab CLI with typed state and explicit teardown contract"
```

---

### Task 6: Boot a guest, the `s0-base` scenario

**Files:**
- Create: `lab/build-disk.sh`
- Create: `manifests/builder.txt`
- Create: `tests/scenarios/s0-base.sh`
- Create: `docs/runbooks/first-boot.md`

**Interfaces:**
- Consumes: `lab up|down|status` from Task 5, `lab_image` from Task 2, state
  schema from Task 5.
- Produces: `lab/build-disk.sh <role> <out.qcow2>` using image-builder, wired
  into `lab up` before the volume is created.

- [ ] **Step 1: Write the failing test**

`tests/scenarios/s0-base.sh`:

```bash
lab up s0-base
addr=$(python3 -c 'import json;print(json.load(open("run/s0-base/state.json"))["nodes"]["base-a"]["address"])')

assert_eq "domain running" "running" "$(virsh domstate ultus-s0-base-base-a)"
assert_ok "guest reachable" timeout 120 bash -c "until ping -c1 -W1 $addr; do sleep 2; done"
assert_eq "name resolves to the guest" "$addr" "$(dig +short +time=2 @$addr base-a.lab.internal | tail -1)"
assert_eq "NXDOMAIN is empty" "" "$(dig +short +time=2 @$addr absent.lab.internal)"
assert_ok "cloud-init finished" ssh -i lab-secrets/id_ed25519 -o StrictHostKeyChecking=no \
  "root@$addr" 'cloud-init status --wait | grep -q "status: done"'
assert_ok "no libvirt dnsmasq on the segment" \
  bash -c "! pgrep -af 'dnsmasq.*ultus-s0-base'"
lab down s0-base
assert_ok "no domain left" bash -c "! virsh list --all --name | grep -q ultus-s0-base"
assert_ok "seed removed"   bash -c "! test -e run/s0-base/seed"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/scenarios/s0-base.sh`
Expected: FAIL at `lab up s0-base`, because `s0-base` is not in the spec yet.

- [ ] **Step 3: Add the node, the blueprint and the disk build**

Add `base-a` to `lab.toml` with `role = "dns"`, one `mgmt` interface and no
second network. `s0-base` and `s1-dns` never share a node name.

`manifests/builder.txt` pins the builder by digest. Resolve the digest once,
record it here and in `docs/runbooks/first-boot.md`, and never use `:latest`:

```bash
podman run --rm --privileged --security-opt label=type:unconfined_t \
  -v "$PWD/build/vm/blueprint.toml:/config.toml:ro" \
  -v "$PWD/build/vm:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "$(cat manifests/builder.txt)" \
  build --type qcow2 --rootfs xfs --output /output \
  --config /config.toml "$(lab_image "$role")"
```

The image name is positional, the blueprint is `--config`, and the qcow2 lands
at `build/vm/qcow2/disk.qcow2`. The builder is
`quay.io/centos-bootc/bootc-image-builder`, pinned by digest in
`manifests/builder.txt`.

The builder refuses rootless podman, and rootful podman cannot see an image in
the user's storage. `build-disk.sh` reads the builder from
`${LAB_PODMAN:-podman}`, refuses rootless podman by name, and copies the image
into that storage on every cache miss. It then compares the id in that storage
with the id it built, and fails on a mismatch. A tag can exist there and point
at an older image, and a builder given that tag emits a disk that boots but
runs none of the current module code. The qcow2 is cached at
`build/vm/cache/<role>-<image-id>.qcow2` beside a `<disk>.id` file holding the
full id, so the privileged step runs once per image and a later `lab up` needs
no root. A cache hit requires that id file, so a disk of unrecorded origin is
rebuilt rather than served, and `lab doctor` still asks for rootful podman while
one is pending. The builder writes into a fresh
`build/vm/build-XXXXXX` directory and hands the output back with `--chown`,
because a rootful run leaves its output root-owned and a reused path then
cannot be cleaned. `tests/test-lab.sh` proves each path with a fake `podman`: a
cache hit never runs the builder, rootless podman is refused, a stale build
storage is reloaded, a mismatched load fails, and a cache entry without its id
file is rebuilt.

`blueprint.toml` sets the root filesystem to `xfs` and the operator user with
the key from `lab-secrets/id_ed25519.pub`, read at build time and never
committed. `lab up` calls `build-disk.sh` before creating the volume, then
copies the cached disk into the scenario directory.

Booting the guest corrected five assumptions, each of which fails silently:

- libvirt's default `qemu64` CPU model lacks SSE4.2, which CentOS Stream 10
  requires, so the domain pins `<cpu mode='host-passthrough'/>` and enables
  `<acpi/>` and `<apic/>`.
- The system-mode daemon does not share the caller's working directory, so every
  `<source file=…>` is absolute.
- `network-config` matches the NIC by MAC, because the guest names a virtio NIC
  `ens2`, and spells the default route `0.0.0.0/0`, because cloud-init 24.4
  raises on `to: default` and then drops the whole config.
- The qemu user must be able to traverse the run directory. A `0700` home is
  common, so `lab doctor` names the gap and `LAB_RUN_DIR` relocates the tree.
- A file-backed console is created root-only, so the domain keeps a pty console
  and a `qemu-guest-agent` channel instead.

`docs/runbooks/first-boot.md` names every mechanism this scenario exercises
(`bootc` install, the NoCloud seed, `systemd`, `qemu-guest-agent`) with the
Windows equivalent beside it, and states where each analogy breaks.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/scenarios/s0-base.sh`
Expected: all `ok`, and `virsh list --all` shows nothing after teardown.

- [ ] **Step 5: Commit**

```bash
git add lab/build-disk.sh manifests/builder.txt lab/lab.toml tests/scenarios/s0-base.sh docs/runbooks/first-boot.md
git commit -m "feat: s0-base boots a bootc guest from image-builder output"
```

---

### Task 7: The `s1-dns` scenario, delegation and failover

**Files:**
- Create: `tests/scenarios/s1-dns.sh`
- Modify: `lab/lab.toml` (two `s1-dns` nodes)
- Modify: `modules/dns/var/named/lab.internal.zone` (delegation records)
- Modify: `modules/dns/usr/libexec/ultus-corp/provision.sh` (secondary mode)

**Interfaces:**
- Consumes: everything from Task 6.
- Produces: a primary and a secondary that both answer, a delegation stub for
  `ipa.lab.internal`, and a boot-time secondary configuration driven by the
  seed.

- [ ] **Step 1: Write the failing test**

`tests/scenarios/s1-dns.sh` asserts: both nodes answer
`base-a.lab.internal`; the secondary answers after the primary is suspended
with `virsh suspend`; `dig +norec` to the primary returns `aa` for
`lab.internal`; and `dig SOA ipa.lab.internal` returns the delegation record.
Each assertion records the full dig output, not just success.

```bash
assert_ok "secondary answers after failover" bash -c "
  virsh suspend ultus-s1-dns-dns-a
  for i in \$(seq 12); do
    dig +short +time=2 @${dns_b} base-a.lab.internal | grep -qx ${addr_a} && exit 0
    sleep 5
  done
  exit 1"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/scenarios/s1-dns.sh`
Expected: FAIL, `dns-b does not answer`, because only one node is defined.

- [ ] **Step 3: Add the second node and the delegation**

`lab.toml` gains `dns-b` in the `mgmt` segment with `role = "dns"` and
`secondary = "dns-a"`. The renderer writes that field into
`/run/ultus-corp/node.json` through the seed. `provision.sh` reads it and
writes the `type secondary` stanza with `masters` and `allow-transfer`, or the
primary stanza with `also-notify`. Nothing node-specific is written at build
time.

The zone file carries an `NS` delegation to `ipa.lab.internal` with an `A` for
the future FreeIPA host. The record exists before the host does, so the
delegation is proven independently of the identity work.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/scenarios/s1-dns.sh`, then `lab down s1-dns`.
Expected: all `ok`, and the teardown check passes.

- [ ] **Step 5: Commit**

```bash
git add lab/lab.toml modules/dns tests/scenarios/s1-dns.sh
git commit -m "feat: s1-dns primary, secondary and delegation"
```

---

### Task 8: CI, supply chain, and the repin workflow

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/repin-base.yml`
- Create: `.github/dependabot.yml`
- Create: `manifests/base.signer`
- Create: `tests/test-ci.sh`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `tests/test-static.sh`, `tests/test-image.sh`, `tests/test-packages.sh`, `tests/test_render.py`, `tests/test-lab.sh`.
- Produces: a CI gate that scans and signs the pushed digest of each role image, and a weekly digest bump PR that fails closed when the signer is unknown.

- [ ] **Step 1: Write the failing check**

`tests/test-ci.sh` asserts `ci.yml` has a `build` job with
`permissions: packages: write`, a `podman push` to `ghcr.io/ultus-net/`, a
`supply` job with `needs: build`, and `cosign sign` naming a digest. It asserts
`repin-base.yml` runs `cosign verify` with `--certificate-identity` and
`--certificate-oidc-issuer` read from `manifests/base.signer`, and that a
missing signer file fails the job. Run it: `bash tests/test-ci.sh` fails, no
workflow file.

- [ ] **Step 2: Write the workflows**

`ci.yml` jobs: `static`, `matrix` over `[dns]` for build plus
`tests/test-packages.sh`, `render` on Python 3.12, `lab` with a fake virsh, and
`supply` which pulls the pushed digest, runs `trivy image --exit-code 1
--severity CRITICAL`, writes the SBOM with `syft`, and signs that digest with
`cosign` keyless. The scan and the signature name the same digest, so the
artifact that was scanned is the artifact that was signed.

`repin-base.yml` runs weekly, resolves the `stream10` tag to a digest, runs
`cosign verify` against it with the exact issuer and identity in
`manifests/base.signer`, and opens a PR that edits `manifests/base.txt` only.
When verification fails, the job fails and opens no PR.

- [ ] **Step 3: Run the checks**

Run: `bash tests/test-ci.sh` and `bash tests/test-static.sh`.
Expected: both pass, and `actionlint` reports no error when installed.

- [ ] **Step 4: Commit**

```bash
git add .github manifests/base.signer tests/test-ci.sh CHANGELOG.md
git commit -m "feat: CI gates, digest-scoped signing and verified repin"
```

---

### Task 9: Isolation gate, budgets, runbooks, and the phase close

**Files:**
- Create: `tests/test-isolation.sh`
- Create: `docs/runbooks/scenarios.md`, `docs/runbooks/isolation.md`
- Create: `tests/fixtures/network-safe.xml`, `tests/fixtures/network-leaking.xml`
- Modify: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `render.py --scenario` output, `lab doctor --host-uplinks`, `lab prune`.
- Produces: the gate that makes the public repo safe to publish, and the budget
  measurement that makes the footprint claim checkable.

- [ ] **Step 1: Write the failing test**

`tests/test-isolation.sh` renders every scenario and asserts each network XML
contains no `<forward`, no `<dhcp`, no
`<bridge name=`, and `<dns enable='no'/>`. It asserts every lab CIDR is
disjoint from every non-default CIDR in `ip -j route show`, using
`lab doctor --host-uplinks` for the physical addresses. It asserts a
deliberately leaking fixture fails the same function, so the gate is not
vacuous. It asserts each scenario's node count and RAM sum stay within its
declared budget.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-isolation.sh`
Expected: FAIL, `tests/test-isolation.sh: no such file`. After the gate exists,
the safe fixture passes and the leaking fixture fails. A gate that passes both
is the failure mode this task exists to catch.

- [ ] **Step 3: Implement the gate and the runbooks**

The gate reads rendered XML, not live `virsh` output, so it runs in CI and on a
host with no domain up. `lab doctor --host-uplinks` prints the host's physical
addresses and prefixes, excluding the default route and every `ultus-*`
interface, so the comparison cannot flag the lab's own networks.

`test-isolation.sh` also runs the Task 1 checks on the real tree, not only on
fixtures:

```bash
assert_ok "real base pin"       check_base_pin manifests/base.txt Containerfile.*
assert_ok "real manifests"      check_manifest_one_per_line manifests/packages-*.txt
assert_ok "real tree secrets"   check_no_secret_patterns .
assert_ok "real role records"   check_role_records docs/roles
```

The secret scan skips `run/` and `.git/`. The media scan skips
`tests/fixtures/`, which holds one deliberate `.iso` fixture.

`docs/runbooks/scenarios.md` documents the one-scenario contract, the
ten-minute rebuild rule, the teardown expectation, the measured wall time and
peak RSS of `s0-base`, and a table with a Linux-mechanism column and a
Windows-bridge column. `docs/runbooks/isolation.md` documents why no bridge
exists and what to check before publishing.

- [ ] **Step 4: Run the full gate set**

Run:
`bash tests/test-static.sh && bash tests/test-image.sh dns && bash tests/test-packages.sh && python3 -m unittest tests.test_render -v && bash tests/test-lab.sh && bash tests/test-ci.sh && bash tests/test-isolation.sh`

Expected: every gate passes, and the command line is recorded in
`docs/runbooks/scenarios.md` as the P0 acceptance line.

- [ ] **Step 5: Commit**

```bash
git add tests/test-isolation.sh tests/fixtures docs README.md CHANGELOG.md
git commit -m "feat: isolation gate, budget checks and P0 runbooks"
```

---

## Self-Review

**Spec coverage.** P0 and s0-base come from the design's Scenarios table. The
static, build, image, scenario, teardown, supply-chain and isolation gates are
Tasks 1, 2, 3, 6, 5, 8 and 9. The scenario model's six rules are covered by
Tasks 4, 5, 6 and 9: budgets and measured footprint in Task 9, symmetric
teardown in Task 5. The Audience rule is executable through the evidence
recorder (Task 1), the role record (Tasks 1 and 3), and the runbook columns
(Tasks 6 and 9). The update gate is seeded in P0 by `greenboot` and the health
check, and proved in s11.

**Step scan.** Every step names a file, a command and an expected result. The
renderer step states the MAC derivation, the isolated-network rule and the seed
schema because a signature cannot carry them. The teardown step states the
failure contract because a passing test cannot.

**Type consistency.** `load`, `nodes_for`, `network_xml`, `domain_xml`,
`interface_mac` and `seed_files` keep one signature across Tasks 4, 5 and 6.
`build_role`, `base_ref` and `lab_image` keep one signature across Tasks 2, 3
and 6. The state schema is stated once in Task 5 and consumed verbatim in
Tasks 6 and 7. The domain name contract `ultus-<scenario>-<node>` is stated
once in Task 4 and reused in Tasks 5, 6, 7 and 9.

**Review Focus.** Eight risks, each with a test: partial state and failed
cleanup (Task 5), name collision (Tasks 4 and 5), host overlap (Task 9),
package drift (Tasks 2 and 3), libvirt dnsmasq (Tasks 4, 6 and 9), stale seed
(Tasks 4, 5 and 6), silent green (Task 1), and a vacuous isolation gate
(Task 9).

**Proportion.** Nine tasks for two scenarios plus the harness. The code blocks
are fixtures, assertions and one build invocation, not implementation bodies.

## Plan sequence after this one

| Plan | Scenarios | Why it is separate |
| --- | --- | --- |
| 1, this plan | s0, s1 | Harness plus the first service |
| 2 | s2, s3 | Packet path: relay, routing, policy, overlay |
| 3 | s4, s5 | Trust and identity |
| 4 | s6, s9 | 802.1X and endpoint onboarding |
| 5 | s7, s8 | Delivery and observability |
| 6 | s10, s11, assembly | Stateful roles, the update gate, then the assembly checks |
