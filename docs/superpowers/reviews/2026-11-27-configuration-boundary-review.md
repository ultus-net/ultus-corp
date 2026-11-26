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

The build half holds. The deploy half is unstated. The maintenance half leaks.

The draft already treats configuration as an artifact: one image per role, a
pinned base, a checked-in package manifest, a build-time file tree, and an
anti-goal against hand-configured VMs. What it does not state is the other half
of the same idea: how per-instance values reach a host at deployment, and what
guarantees they are applied once and never converge afterwards. Without that,
"configured as part of deployment" is an intention, not a contract.

Two further findings are correctness issues rather than framing issues. The
atomic rollback the design promises covers `/usr`, and 12 of its 17 roles keep
state in `/var`. Quadlet roles add a second update plane that the image does not
own.

## 1. The model, stated precisely

| Layer | Owns | Home | Changes on |
| --- | --- | --- | --- |
| Source | templates, value schema, non-secret values, manifests, tests | this repository | a reviewed commit |
| Image | packages, `/usr`, static config, units, container digests | the image digest | a build |
| Deployment | hostname, addresses, keys, site values | `/etc` and the NoCloud seed | host creation or re-creation |
| Runtime | users, DNS records, realms, reservations | the service API | an operator decision |

Rules that make the model hold:

1. A change that would make two hosts from the same digest differ in `/usr`
   belongs in the image.
2. A per-instance value is a deployment input. It is declared in the repository
   and rendered once. It is never edited on the host.
3. Secret material is generated per host and referenced, never committed. The
   repository owns the schema and the public or non-secret values.
4. Deployment is one shot. Nothing re-applies configuration on a running host.
   A drifted host is re-rendered or replaced, not repaired in place.
5. Runtime automation may create or change API objects only. It may not change
   host files.

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

### F1. The deployment input contract is unnamed (P1)

The model requires a declared, rendered-once input set. The draft has the
mechanism (D11, `:234`) and even a freshness rule in the plan's review focus
("each `up` writes a fresh seed and refuses to reuse a key already claimed by
another host"), but it never says what the seed contains, who renders it, or
that a second boot applies nothing.

Consequence: the seed becomes the new snowflake. The anti-goal at `:98` stays
untestable, because a host can differ from its image through the seed and no
gate would notice.

Change: add a deployment-inputs section with a schema in `lab/lab.toml`, a
render step in the `lab` CLI, and a seed contract limited to identity. Pin
`cloud-init` to once-per-instance modules and ban `always` modules. Assert that
a second boot applies nothing and leaves the digest unchanged.

### F2. Atomic rollback does not cover state (P1)

The model requires that a bad deployment can be undone. The draft promises
"atomic upgrade and rollback" in D1 (`:224`) and proves it in s0 (`:149`), which
boots one stateless role.

Twelve of the 17 roles in the roles table are marked stateful (`:326-344`):
dhcp, pki, ipa, app, registry, mon, secrets, mdm, deploy, print, file, ipam.
bootc reverts `/usr`; `/var` persists across deployments, and the bootc
documentation says an update or rollback "should not affect this application
data". NetBox and Keycloak do not support a schema downgrade. A rollback that
boots older binaries against newer data is an outage, not a rollback.

Change: state a rollback contract per role. Stateless and config-only roles roll
back by deployment. Stateful roles are forward-only, with a pre-upgrade snapshot
and a restore test. Prove one stateful upgrade, not just the s0 path.

### F3. Quadlet roles create a second update plane (P2)

The model requires one artifact to describe the deployed state. Keycloak and
Gitea run as Quadlets (`:335`), so they can update outside the image if a unit
opts into registry auto-update.

Consequence: "the image is the unit of build and test" (`:346`) is false for the
roles that use Quadlet, and the change record splits in two.

Change: pin every container by digest in the image, set no `AutoUpdate=registry`,
and mask the auto-update timer. bootc is the only update plane.

### F4. Drift is not asserted (P2)

The model requires that the host matches its artifact. `/etc` is writable and
three-way merged on upgrade, so a local edit survives and overrides the image on
the next update. No gate checks it.

Consequence: the design's "no hand configuration" rule has no detection surface.

Change: every scenario asserts `bootc status --json` reports the expected digest
and `ostree admin config-diff` is empty for managed paths.

### F5. First-boot installs are implicit (P2)

The model allows exactly one deploy-time step. FreeIPA, step-ca, OpenBao and
Fleet need a first-boot install that writes `/etc` and `/var`, and the draft
never names it. `bootc container lint` will also warn about missing
`tmpfiles.d` entries for the stateful roles.

Consequence: the first-boot step grows without a contract, and it is discovered
in s5 instead of designed in s0.

Change: define a oneshot contract per role: idempotent, fail-closed, runs once,
asserted by its scenario. Use the vendor collection where one is supported,
notably `freeipa.ansible_freeipa`.

### F6. The real-rebuild claims outrun the evidence (P3)

`§Reuse in a real rebuild` says role images transfer unchanged (`:401-407`) and
lists what is unproven (`:417-422`). A bare-metal server install medium is
missing from that list: the lab proves the qcow2 plus NoCloud path only, and PXE
is for endpoints.

Separately, 17 role images multiplied by Stream 10's repin cadence is the
project's main maintenance cost. A shared `ultus-corp/base` layer turns a repin
into one base plus 17 thin layers.

Change: add the install medium to the not-proven table, and build the roles on a
shared base layer.

## 4. Tooling position

### Keep

| Tool | Role | Why |
| --- | --- | --- |
| bootc | image build, transport, atomic deploy | Makes the deployed state one digest, which is the property the model needs |
| cloud-init + NoCloud seed | one-shot deployment inputs | Already the chosen path (D11); narrow it to identity |
| `lab` renderer | spec to domain XML and seed | Deterministic, stdlib only, and the branch-as-data requirement depends on it |
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
- Salt is Broadcom-owned. 3008 moved a large module set out of core, and the
  published lifecycle stops at 3008 LTS.

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

- never `package`, never `/usr`, never service enablement, never a baseline;
- run it from a lab VM or container, not the workstation, so the host keeps its
  stdlib-only constraint (plan global constraints);
- the playbook may change API objects and `/etc` inputs only. If a change would
  make two hosts from the same digest differ in `/usr`, it is in the wrong tool.

Rejected alternatives: Ignition overlaps cloud-init, which the base already
ships. OpenTofu covers 2 of the 6 API object types (NetBox, Keycloak) and none
of FreeIPA, Kea or Fleet, so it would be a third tool for partial coverage.

## 5. Changes applied in this PR

The second commit accepts the findings into the spec:

- D20: rollback contract per role.
- D21: one update plane.
- `§Configuration and deployment inputs`: the four-layer model and its rules.
- Gates 10 to 12: drift, deployment idempotence, stateful rollback.
- A risk row for stateful rollback, and the install medium in the not-proven
  table.

No runtime dependency is added and no tool is adopted. The only optional
addition remains Ansible behind the trigger in section 4.

## 6. What would change this recommendation

- A role whose vendor supports runtime installation only, at the scale the lab
  needs. Then the first-boot contract moves, and Ansible owns a named slice.
- A requirement for per-host mutation that cannot be expressed as a deployment
  input. Then the boundary is wrong, not the tooling.
- A drift requirement that a digest comparison cannot satisfy. Then add a
  detector, not a converger.

Record the trigger in the design when it fires. Do not adopt the tool ahead of
it.

## 7. Evidence

Repository:

- `docs/superpowers/specs/2026-11-26-ultus-corp-design.md` at `9258c00`.
- `docs/superpowers/plans/2026-11-26-ultus-corp-plan.md` at `9258c00`.

External:

- bootc filesystem and configuration model: <https://bootc.dev/bootc/>
- Red Hat image mode, build-time packages and runtime configuration:
  <https://developers.redhat.com/articles/2025/03/18/how-use-rhel-system-roles-image-mode>
- RHEL image mode, day 1 and day 2: <https://redhatquickcourses.github.io/rhde-bootc-build/rhde-bootc-build/1/ch1-intro/s1-rhde-and-image-mode.html>
- OpenVox history: <https://docs.openvoxproject.org/ecosystem/latest/history.html>
- Chef supported versions: <https://docs.chef.io/versions/>
- Salt lifecycle: <https://docs.saltproject.io/salt/install-guide/en/latest/topics/salt-version-support-lifecycle.html>
- NetBox upgrade policy: <https://netboxlabs.com/docs/netbox/installation/upgrading/>
- Keycloak schema downgrade: <https://forum.keycloak.org/t/downgrade-rollback-of-keycloak/24990>
