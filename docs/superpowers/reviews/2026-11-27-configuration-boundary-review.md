# Configuration boundary review

**Status:** review for the design owner, 2026-11-27
**Subject:** `docs/superpowers/specs/2026-11-26-ultus-corp-design.md`, draft of 2026-11-26
**Reviewed at:** commit `9258c00`
**Question:** does the design hold the intended model, where configuration is a
versioned artifact in the repository and is applied at deployment time, rather
than converged on a running host?

Line references below are to `9258c00`. Section and decision ids survive later
edits, so prefer those when the two disagree.

## Verdict

The build half holds. The deploy half is unstated. The maintenance half leaks in
three classes, not one.

The draft already treats configuration as an artifact: one image per role, a
pinned base, a checked-in package manifest, a build-time file tree, and an
anti-goal against hand-configured VMs. What it does not state is the other half
of the same idea: how per-site service values reach a host, and what guarantees
they are applied once and never converge afterwards.

Three findings are correctness issues. Deployment values have no contract, and
the plan already mixes a build-time script with a deployment value. Atomic
rollback covers `/usr`, while 12 of 17 roles keep state in `/var`. Quadlet roles
sit in a second artifact plane that the image does not own.

## 1. The model, stated precisely

| Layer | Owns | Home | Changes on |
| --- | --- | --- | --- |
| Source | templates, value schema, non-secret values, manifests, tests | this repository | a reviewed commit |
| Image | packages, `/usr`, static config, units, bound container digests | the image digest | a build |
| Deployment | identity and per-site service values, rendered | the NoCloud seed, written to `/etc` and `/var` | host creation or re-creation |
| Runtime | users, DNS records, realms, reservations | the service API | an operator decision |

Rules that make the model hold:

1. A change that would make two hosts from the same digest differ in `/usr`
   belongs in the image.
2. A per-instance value is declared in the repository and rendered into a file
   at deployment. The guest never templates it. An operator never edits it on
   the host.
3. Secret material is generated per host and referenced, never committed. The
   repository owns the schema and the public or non-secret values.
4. Deployment is one shot. It ends when `cloud-init` and the role's installer
   both report success. Nothing converges host state afterwards.
5. Runtime automation may create or change API objects only. It may not change
   host files after deployment ends.

The boundary is not "image versus configuration management". It is "which layer
owns this value, and what is allowed to change it after deployment".

## 2. Where the draft already holds the model

| Design element | Evidence | Verdict |
| --- | --- | --- |
| One image per role, image is the unit of build and test | `§Roles and images` (`:326-348`) | holds |
| A role is replaced by changing an image reference | `§Intent` (`:23`) | holds |
| Every scenario rebuilds from the repository, from an empty host | `§Goals` (`:68`) | holds |
| Hand-configuring a VM outside the checked-in spec is an anti-goal | `§Anti-goals` (`:98`) | holds |
| Base pinned by tag and digest | `§Gates` item 1 (`:450`); plan global constraints | holds |
| Build-time assertions of enablement | `§Roles and images` (`:350-354`) | holds |
| Signed images, SBOM, trivy gate | D13 (`:236`), gate 8 (`:462`) | holds |
| NoCloud seed per deployment | D11 (`:234`) | half-built; see F1 |

## 3. Findings

### F1. Deployment inputs are unstated, and the plan contradicts itself (P1)

The model requires a declared, rendered-once input set. The draft has the
mechanism (D11, `:234`) and a freshness rule in the plan's review focus ("each
`up` writes a fresh seed and refuses to reuse a key already claimed by another
host"), but no contract for what the seed carries or who renders it.

The plan then demonstrates the gap. Task 7 puts `50-dns.sh` under
`usr/libexec/ultus-corp/build.d/` (`plan:205-208`), which runs at image build
(`plan:246`), and has it write `also-notify` and `allow-transfer` from a value
the renderer passes in the seed at deployment (`plan:537-538`). A build-time
script cannot read a deployment value. Either the value is rendered at deploy,
or the branch becomes an image variant.

Consequence: per-site values force image variants, or the guest templates at
runtime, which is the thing the model forbids. The seed also carries keys and an
enrolment token with no stated permissions, deletion or log rule.

Change: the `lab` renderer writes per-role configuration into the seed, and the
guest copies it into place. The seed carries identity, rendered configuration and
first-boot secret material only. It is mode 0600, never logged, and ejected and
deleted when deployment ends; teardown tolerates its absence, so a later `up` and
`down` still work. Cached user-data is scrubbed, because `cloud-init` retains the
raw input under `/var/lib/cloud/instance/`. Build-time scripts enable units; they
never consume a deployment value.

### F2. Atomic rollback is not a data rollback (P1)

The draft promises "atomic upgrade and rollback" in D1 (`:224`) and proves it in
s0 (`:149`), which boots one stateless role.

Twelve of the 17 roles in the roles table are stateful (`:326-344`): nine carry
application state (dhcp, pki, ipa, app, registry, mon, secrets, mdm, ipam) and
three are file-backed (deploy, print, file). The spec change below moves the DNS
primary into application state as well, taking the count to 13. bootc reverts
`/usr`; `/var` persists across deployments, and the bootc filesystem
documentation says a rollback "should not affect this application data".

Schema downgrade is not a safe assumption: NetBox migrations are not guaranteed
reversible, and Keycloak reports that a downgraded server cannot use an upgraded
schema. A filesystem snapshot is also not an application-consistent backup, and
the draft does not say in what order a restore runs or which image it restores
into.

Change: a rollback class per role, a recorded procedure, and one exercised role
per class. Stateful roles quiesce, back up with the application's own tool, and
restore into the matching image. They never roll back by image alone.

### F3. Quadlet roles are a second artifact plane (P1)

Keycloak and Gitea run as Quadlets (`:335`). Podman pulls them into
`/var/lib/containers`, which is separate from bootc's image storage. A floating
reference is therefore outside the image digest, outside `bootc rollback`,
outside offline boot, and outside the image SBOM. Disabling auto-update removes
the second update trigger but does not put the image in the artifact.

Change: declare the Quadlets as bootc logically bound images under
`/usr/lib/bootc/bound-images.d`, pinned by digest, and set
`GlobalArgs=--storage-opt=additionalimagestore=/usr/lib/bootc/storage` on each
unit so it reads the bootc store. Preload the images during the disk build, and
prove a cold boot with egress off still starts them. The bound set follows the
bootc deployment, so an application update is a host image build, not an
in-place pull. The alternative is to accept a second artifact plane explicitly,
with its own signing, scanning, availability and rollback contract. The draft
should not leave this implicit.

### F4. The drift gate cannot test what it names (P2)

`ostree admin config-diff` compares all of `/etc` against the origin and has no
path selector, and legitimate deployment writes appear in its output. The bootc
digest also does not move when `cloud-init` or a oneshot writes a file. A gate
built from either one cannot distinguish a hand edit from a deployment.

Change: the scenario records a checksum manifest of every file the deployment
renders, asserts the manifest is unchanged after a second boot, and fails when a
negative test hand-edits one managed file. Oneshot and `cloud-init` invocation
counts are asserted separately.

### F5. First-boot installs are implicit (P2)

The model allows exactly one deploy-time step. FreeIPA, step-ca, OpenBao and
Fleet need a first-boot install that writes `/etc` and `/var` and enables units,
and the draft never names it. `bootc container lint` also warns about missing
`tmpfiles.d` entries for stateful roles.

Change: a oneshot contract per role: idempotent, fail-closed, runs once, asserted
by its scenario. Deployment ends when that unit and `cloud-init` both succeed.
The install may write `/etc` and `/var`; nothing may converge them afterwards.
The application writes its own state under `/var` as it runs.

### F6. The transfer claim fails for DNS (P2)

`§Reuse in a real rebuild` says role images transfer unchanged (`:401-407`), and
`§Not proven here` lists what a rebuild still owes (`:417-422`). Task 7 bakes
`lab.internal.zone` into `modules/dns/var/named/` (`plan:515`). bootc applies
image `/var` content only at initial installation, and the zone must be reissued
for a real rebuild.

Consequence: the DNS image carries a site-specific fact that the transfer table
says it does not.

Change: keep templates under `/usr/share/ultus-corp/`, render the zone at
deployment, and manage runtime records through the declared API or replication
path. The transfer claim becomes "images transfer with their templates; site data
is rendered".

### F7. The build is not reproducible against a mutable repository (P2)

A digest-pinned base does not pin the `dnf` transactions that follow it. Stream
10 repositories move. The plan generates `manifests/*.lock`, but
`Containerfile.dns` installs from the joined `packages.txt` (`plan:181-184`), so
two builds of the same file can resolve different NEVRAs.

Change: consume a resolved NEVRA lock in the build, or build from a snapshot
mirror. Update the base digest and the lock in the same change, and fail the
build on a package outside the lock.

### F8. Two claims outrun their evidence (P3)

"17 role images multiplied by Stream 10's repin cadence is the project's main
maintenance cost" ranks a cost that was not measured. Say "a significant
maintenance cost", or measure it.

"OpenTofu covers 2 of the 6 API object types" uses the wrong denominator. The
list names five families: FreeIPA, Keycloak, Kea, NetBox, Fleet.

## 4. Tooling position

### Keep

| Tool | Role | Why |
| --- | --- | --- |
| bootc | image build, transport, atomic deploy | Makes the deployed state one digest, which is the property the model needs |
| cloud-init + NoCloud seed | one-shot deployment inputs | Already the chosen path (D11); narrow it and control its lifecycle |
| `lab` renderer | spec to domain XML, seed and per-role files | Deterministic, stdlib only, and the branch-as-data requirement depends on it |
| systemd oneshots | first-boot installs | No extra control plane, and the unit is testable inside the image |
| cosign, SBOM, trivy | supply chain | Already gated (D13) |
| Fleet | inventory and policy | Already the endpoint plane (D17) |

### Do not add a configuration-management platform

Every capability the platforms sell is already owned here:

| Capability | Already owned by | A platform would add |
| --- | --- | --- |
| host baseline | the bootc image | a second, mutable source of truth for `/usr` |
| patching | repin, `bootc upgrade`, registry mirror | a package loop that fights the image |
| inventory | Fleet and osquery | a second inventory that drifts |
| compliance | image digest, cosign, SBOM, trivy | a second policy engine |
| secrets | OpenBao and the per-host seed | a second secret store |
| identity and PKI | FreeIPA and step-ca | a second CA and directory |

Supply-chain position, checked 2026-11-27:

- Open-source Puppet was discontinued in late 2024. The community continuation
  is OpenVox, at 9.x, and a critical server RCE was fixed in November 2026.
- Chef Infra Server 15 is deprecated with an EOL of 2026-11-30 and is replaced
  by the SaaS Chef 360 Platform. Automated download of Chef Infra Client 19
  requires a licence key.
- Salt 3008 removed a large set of modules from core, and the published
  lifecycle stops at 3008 LTS.

All three are the wrong dependency for a public, zero-spend, isolated lab whose
whole point is that a host rebuilds from the repository.

### Ansible, if and only if

Use another tool if and only if the change targets something that is not part
of the host image:

- an API object: FreeIPA users, hosts and DNS records, Keycloak realms, Kea
  reservations, NetBox, Fleet policies;
- a first-boot action the vendor does not support at build time, where the
  vendor's supported collection is better than a hand-rolled oneshot.

Triggers, so the decision stays a decision: add it when the directory passes
roughly 20 managed objects, or when s5 reaches the FreeIPA install.

Constraints on its use:

- never `package`, never `/usr`, never a baseline;
- during deployment only, it may run the vendor installer, which writes `/etc`,
  `/var` and enables units. Once deployment ends, it may change API objects
  only;
- run it from a lab VM or container, not the workstation, so the host keeps its
  stdlib-only constraint (plan global constraints).

Rejected alternatives: Ignition overlaps cloud-init, which the base already
ships. OpenTofu covers 2 of the 5 API families (NetBox, Keycloak) and none of
FreeIPA, Kea or Fleet, so it would be a third tool for partial coverage.

## 5. Changes applied in this PR

The spec commit accepts the findings into the draft:

- D20: a per-role rollback contract, with a profile-level class table.
- D21: Quadlets as bootc logically bound images, pinned by digest, read through
  the additional image store, and preloaded so a cold boot with egress off works.
- `§Configuration and deployment inputs`: the four-layer model, the seed
  contract, the secrecy lifecycle, and when deployment ends.
- Gates 10 to 13: managed-file integrity, deployment counts, rollback by class,
  and build reproducibility.
- Risk rows for stateful rollback, the seed ISO, a missing bound image on a cold
  boot, and mutable Stream repositories.
- The missing server install medium in `§Not proven here`.

No runtime dependency is added and no tool is adopted. The only optional
addition remains Ansible behind the trigger in section 4.

## 6. Plan impact

The review is a spec change, but three P0 tasks must follow or the gates are
aspirational:

| Plan task | Change |
| --- | --- |
| Task 3, `Containerfile.dns` | Consume the resolved NEVRA lock instead of `packages.txt` |
| Task 7, `s1-dns` | Render `also-notify` and `allow-transfer` at deploy; move `lab.internal.zone` out of `/var` |
| The gate tasks | Add the managed-file manifest, the invocation counts, one negative hand-edit test, and the lock gate |

P0 proves s0, which is stateless. The first stateful plan must add one upgrade
and restore, or F2 stays untested. Gate 12 is not a P0 exit criterion: it stays
open until one role from each class has run.

## 7. What would change this recommendation

- A role whose vendor supports runtime installation only, at the scale the lab
  needs. Then the first-boot contract moves, and Ansible owns a named slice.
- A requirement for per-host mutation that cannot be expressed as a deployment
  input. Then the boundary is wrong, not the tooling.
- A drift requirement that a checksum manifest cannot satisfy. Then add a
  detector, not a converger.
- Bound images that cannot meet the offline or mirror requirement. Then accept a
  second artifact plane and give it a signing and rollback contract.

Record the trigger in the design when it fires. Do not adopt the tool ahead of
it.

## 8. Evidence

Repository:

- `docs/superpowers/specs/2026-11-26-ultus-corp-design.md` at `9258c00`.
- `docs/superpowers/plans/2026-11-26-ultus-corp-plan.md` at `9258c00`.

External:

- bootc `/var` and filesystem semantics: <https://bootc.dev/bootc/bootc-filesystem.7.html>
- bootc logically bound images: <https://bootc.dev/bootc/bootc-logically-bound-images.7.html>
- Red Hat image mode, build-time packages and runtime configuration:
  <https://developers.redhat.com/articles/2025/03/18/how-use-rhel-system-roles-image-mode>
- RHEL image mode, day 1 and day 2: <https://redhatquickcourses.github.io/rhde-bootc-build/rhde-bootc-build/1/ch1-intro/s1-rhde-and-image-mode.html>
- OpenVox history: <https://docs.openvoxproject.org/ecosystem/latest/history.html>
- OpenVox 9 release notes: <https://docs.openvoxproject.org/openvox/latest/release_notes.html>
- OpenVox critical CVE, November 2026: <https://voxpupuli.org/blog/2026/11/03/critical-cve-updates/>
- Chef supported versions: <https://docs.chef.io/versions/>
- Chef Infra Client 19 licence key: <https://www.chef.io/blog/progress-chef-infra-client-19-release>
- Salt lifecycle: <https://docs.saltproject.io/salt/install-guide/en/latest/topics/salt-version-support-lifecycle.html>
- Salt module migration: <https://saltproject.io/blog/the-great-salt-module-migration/>
- NetBox irreversible migration: <https://github.com/netbox-community/netbox/issues/17830>
- Keycloak schema downgrade: <https://github.com/keycloak/keycloak/issues/14155>
