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
assert_ok "zone file present"      podman run --rm "$img" test -s /var/named/lab.internal.zone
assert_ok "named config valid"     podman run --rm "$img" named-checkconf -z /etc/named.conf
assert_ok "unbound config valid"   podman run --rm "$img" unbound-checkconf /etc/unbound/unbound.conf
assert_ok "provision unit enabled" podman run --rm "$img" systemctl is-enabled ultus-provision.service
assert_ok "health check executable" \
  podman run --rm "$img" test -x /etc/greenboot/check/required.d/50-dns-health.sh
assert_ok "record proof passes"    run_role_proof dns

finish
