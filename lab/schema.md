# ULTUS-CORP lab spec schema

All keys in `lab/lab.toml` are consumed, validated and documented here.

## `[lab]` table

| Key | Type | Required | Default | Rejection |
|-----|------|----------|---------|-----------|
| `realm` | string | yes | - | empty |
| `domain` | string | yes | - | empty |
| `overlay` | string | yes | - | empty or invalid CIDR |

`realm` is the DNS realm for the entire lab (e.g., `LAB.INTERNAL`).
`domain` is the DNS zone (e.g., `lab.internal`).
`overlay` is an isolated address block for overlay networks
(e.g., `10.255.0.0/16`). This network does not forward to the host LAN.

## `[dns]` table

Optional, and required in a spec that runs a DNS role. Every value here is
rendered into the seed, never into an image.

| Key | Type | Required | Default | Rejection |
|-----|------|----------|---------|-----------|
| `serial` | integer | yes | - | < 1 |
| `ttl` | integer | no | 3600 | - |
| `refresh` | integer | no | 3600 | - |
| `retry` | integer | no | 600 | - |
| `expire` | integer | no | 604800 | - |
| `minimum` | integer | no | 300 | - |

`serial` is the zone serial. It is explicit because a rendered zone must not
depend on the clock.

### `[[dns.delegate]]` tables

| Key | Type | Required | Default | Rejection |
|-----|------|----------|---------|-----------|
| `name` | string | yes | - | empty, or not a single label |
| `ns` | string | yes | - | does not end with `.<domain>.` |
| `address` | string | yes | - | not an IPv4 address |

A delegate is a subdomain handed to a node that does not exist yet. The glue
address is declared here, so the delegation is provable before that role is
built.

## `[[site]]` tables

Top-level keys inside a site are invalid.

| Key | Type | Required | Default | Rejection |
|-----|------|----------|---------|-----------|
| `id` | string | yes | - | empty or duplicate |
| `prefix` | string | yes | - | empty or invalid CIDR |

Each site is an address prefix (e.g., `10.100.0.0/16`). The renderer creates
one libvirt network per segment within this prefix.

### `[[site.segment]]` tables

Under each site, segment items are in a list keyed by `[site.segment]`.

| Key | Type | Required | Default | Rejection |
|-----|------|----------|---------|-----------|
| `name` | string | yes | - | empty or duplicate within site |
| `cidr` | string | yes | - | empty or invalid CIDR |

Segments are VLAN-like named networks (e.g., `mgmt`, `data`).

## `[[scenario]]` tables

Top-level keys inside a scenario are invalid.

| Key | Type | Required | Default | Rejection |
|-----|------|----------|---------|-----------|
| `id` | string | yes | - | empty or duplicate |
| `title` | string | no | "" | - |
| `vm_budget` | integer | yes | - | < 1 |
| `ram_budget_mib` | integer | yes | - | < 1 |

Scenarios define the maximum number of VMs and total RAM allowed in that scenario.

## `[[node]]` tables

Top-level keys inside a node are invalid.

| Key | Type | Required | Default | Rejection |
|-----|------|----------|---------|-----------|
| `scenario` | string | yes | - | empty, or a scenario that does not exist |
| `name` | string | yes | - | empty or duplicate |
| `site` | string | yes | - | empty, or a site that does not exist |
| `role` | string | yes | - | - |
| `secondary` | string | no | - | names a node that does not exist, belongs to another scenario, or is itself a secondary |
| `vcpus` | integer | yes | - | < 1 |
| `ram_mib` | integer | yes | - | < 1 |
| `disk_gib` | integer | yes | - | < 1 |

Each node is a host within a scenario. The renderer names domains as
`ultus-{scenario}-{node}` and provides seed files for cloud-init.

`secondary` names the node this one copies its zone from. The renderer resolves
that name to the primary's first interface address and writes the `masters`
stanza into the seed, so a secondary carries no zone file and no other source
for that address. A node named by another node's `secondary` receives the
addresses of its secondaries, which become `allow-transfer` and `also-notify`
entries in its zone stanza.

### `[[node.interface]]` tables

Under each node, interface items are in a list keyed by `[node.interface]`.

| Key | Type | Required | Default | Rejection |
|-----|------|----------|---------|-----------|
| `segment` | string | yes | - | empty or no-existent segment |
| `address` | string | yes | - | empty or outside segment CIDR |
| `gateway` | string | no | "0.0.0.0" | - |
| `nameservers` | list of strings | no | [] | not a list or contains empty/invalid IPs |

Interfaces are declared per segment and must carry a valid address within that
segment's CIDR. The renderer generates a unique MAC per interface using
SHA-256 hashing of the scenario-node-segment string.

## Validation summary

`load()` raises `ValueError` on:
- Missing required keys at any level
- Unknown keys at any level
- Duplicate ids/names at any level (site, scenario, node)
- Invalid CIDR strings
- Address outside declared segment CIDR
- Scenario or site reference missing
- Node set size exceeding scenario's `vm_budget` total
- Node total RAM exceeding scenario's `ram_budget_mib`
- Duplicate MAC addresses (detects early via hash check)
- A `secondary` that names a node in another scenario, or one that is itself a secondary
- An unknown key in `[dns]` or a delegate table
- A delegate `ns` outside the declared domain, or a delegate name with a dot
