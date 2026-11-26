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
# unbound-checkconf accepts a chroot the daemon cannot start inside, so the
# effective chroot is asserted rather than the file's syntax alone.
assert_eq "unbound runs unchrooted" "" \
  "$(podman run --rm "$img" unbound-checkconf -o chroot /etc/unbound/unbound.conf)"

# And the daemon itself has to start and bind. This container path has no
# systemd notify socket, so it cannot reproduce the chroot failure; the
# assertion above is what covers that one.
unbound_binds() {
  podman run --rm "$img" bash -c '
    unbound -d &
    pid=$!
    sleep 3
    kill -0 "$pid" || { echo "unbound exited at startup"; exit 1; }
    ss -lun | grep -q "127.0.0.1:53" || { echo "unbound does not listen on 127.0.0.1:53"; exit 1; }
    kill "$pid"
  '
}
assert_ok "unbound starts and binds loopback" unbound_binds
assert_fails "the health check fails without a resolver" \
  podman run --rm -e ULTUS_HEALTH_TRIES=1 "$img" \
  /etc/greenboot/check/required.d/50-dns-health.sh
assert_ok "provision unit enabled" podman run --rm "$img" systemctl is-enabled ultus-provision.service
assert_ok "health check executable" \
  podman run --rm "$img" test -x /etc/greenboot/check/required.d/50-dns-health.sh
assert_ok "record proof passes"    run_role_proof dns

finish
