#!/usr/bin/env bash
# The greenboot wiring that the rollback proof depends on, without a hypervisor.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/common.sh
img=$(lab_image dns)

assert_eq "greenboot health check is enabled" "enabled" \
  "$(podman run --rm "$img" systemctl is-enabled greenboot-healthcheck.service)"
assert_ok "bootc can roll back" \
  podman run --rm "$img" bootc rollback --help
assert_ok "the dns health check is a required check" \
  podman run --rm "$img" test -x /etc/greenboot/check/required.d/50-dns-health.sh

# A required check must fail when the service it names is absent. Without this,
# a green boot proves nothing: the check would pass on any image.
assert_fails "the health check fails with no resolver" \
  podman run --rm -e ULTUS_HEALTH_TRIES=1 "$img" \
  /etc/greenboot/check/required.d/50-dns-health.sh
assert_ok "the failure names the zone" \
  bash -c "podman run --rm -e ULTUS_HEALTH_TRIES=1 '$img' /etc/greenboot/check/required.d/50-dns-health.sh 2>&1 | grep -q 'no SOA for lab.internal'"

# The throwaway check ships under /usr so a rollback removes it. The marker is
# on /var, which a rollback keeps, so it can prove the failing boot happened.
assert_fails "the broken check fails" \
  podman run --rm -v "$PWD/tests/fixtures/greenboot:/broken:ro" "$img" \
  bash -c 'install -m 0755 /broken/99-broken.sh /tmp/99-broken.sh && /tmp/99-broken.sh'
assert_ok "the broken check leaves its marker" \
  bash -c "podman run --rm -v '$PWD/tests/fixtures/greenboot:/broken:ro' '$img' bash -c 'install -m 0755 /broken/99-broken.sh /tmp/99-broken.sh; /tmp/99-broken.sh || true; test -e /var/lib/ultus-corp/greenboot-broken-proof'"

finish
