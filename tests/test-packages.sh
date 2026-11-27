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

assert_ok "bind installed"         podman run --rm "$img" rpm -q bind
assert_ok "unbound installed"      podman run --rm "$img" rpm -q unbound
# Configuration is deployment data. An image that shipped it would answer with
# whatever address the last build happened to bake in.
assert_ok "no zone shipped"        podman run --rm "$img" bash -c '! test -e /var/named/lab.internal.zone'
assert_ok "applier installed"      podman run --rm "$img" test -x /usr/libexec/ultus-corp/provision.sh
assert_ok "no seeded fact file"    podman run --rm "$img" bash -c '! test -e /run/ultus-corp/node.json'

# The daemon-level startup assertion lives in the provision gate, where the
# rendered configuration is present. This container path has no systemd notify
# socket, so the health check below is what covers the required check here. A
# record marks the host as deployed, which is when the check must judge it.
assert_fails "the health check fails without a resolver" \
  podman run --rm -e ULTUS_HEALTH_TRIES=1 "$img" bash -c \
  'mkdir -p /var/lib/ultus-corp/deployments && : > /var/lib/ultus-corp/deployments/deployed.json && exec /etc/greenboot/check/required.d/50-dns-health.sh'
assert_ok "provision unit enabled" podman run --rm "$img" systemctl is-enabled ultus-provision.service
assert_ok "health check executable" \
  podman run --rm "$img" test -x /etc/greenboot/check/required.d/50-dns-health.sh
assert_ok "record proof passes"    run_role_proof dns

finish
