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
assert_ok "the shared deployment gate ships" \
  podman run --rm "$img" test -f /usr/libexec/ultus-corp/deployed.sh
assert_ok "the dns check sources the shared gate" \
  podman run --rm "$img" grep -q 'ultus-corp/deployed.sh' \
  /etc/greenboot/check/required.d/50-dns-health.sh
# The vendor unit is pulled by multi-user, and cloud-final is ordered after
# multi-user. Ordering the check after cloud-final builds a cycle that deletes
# the check, so a green boot would pass unproven.
assert_ok "greenboot is not ordered after cloud-final" \
  podman run --rm "$img" bash -c \
  'test -f /usr/lib/systemd/system/greenboot-healthcheck.service \
   && ! grep -q "^After=.*cloud-final" /usr/lib/systemd/system/greenboot-healthcheck.service \
   && ! test -e /usr/lib/systemd/system/greenboot-healthcheck.service.d/10-after-deploy.conf'
assert_ok "an unprovisioned first boot is not judged" \
  bash -c "podman run --rm -e ULTUS_HEALTH_TRIES=1 '$img' /etc/greenboot/check/required.d/50-dns-health.sh 2>&1 | grep -q 'first boot is not judged'"

# A delivered id without its record means the deployment did not finish. The
# check must refuse rather than judge the image's default configuration.
delivered_id=c1cfba26-9fc0-4f7d-8b73-ee463e8df2d0
assert_fails "a delivered id without a record fails the check" \
  podman run --rm -e ULTUS_DEPLOY_TRIES=1 "$img" bash -c \
  "mkdir -p /run/ultus-corp && printf '%s\n' $delivered_id > /run/ultus-corp/deployment-id && /etc/greenboot/check/required.d/50-dns-health.sh"
assert_ok "the failure names the unfinished deployment" \
  bash -c "podman run --rm -e ULTUS_DEPLOY_TRIES=1 '$img' bash -c \"mkdir -p /run/ultus-corp && printf '%s\n' $delivered_id > /run/ultus-corp/deployment-id && /etc/greenboot/check/required.d/50-dns-health.sh\" 2>&1 | grep -q 'deployment $delivered_id did not record'"
# A record for another deployment must not mask the delivered id's absence.
assert_fails "another deployment's record does not satisfy the id" \
  podman run --rm -e ULTUS_DEPLOY_TRIES=1 "$img" bash -c \
  "mkdir -p /run/ultus-corp /var/lib/ultus-corp/deployments && printf '%s\n' $delivered_id > /run/ultus-corp/deployment-id && printf '{}\n' > /var/lib/ultus-corp/deployments/00000000-0000-4000-8000-000000000000.json && /etc/greenboot/check/required.d/50-dns-health.sh"
# The applier refuses an id that is not a lowercase UUIDv4, so the check must
# refuse the same shape instead of waiting on a record path it cannot hold.
bad_id=c1cfba26-9fc0-1f7d-8b73-ee463e8df2d0
assert_fails "a delivered id that is not a UUIDv4 is refused" \
  podman run --rm -e ULTUS_DEPLOY_TRIES=1 "$img" bash -c \
  "mkdir -p /run/ultus-corp && printf '%s\n' $bad_id > /run/ultus-corp/deployment-id && /etc/greenboot/check/required.d/50-dns-health.sh"
# With the record present the check moves on to the service it validates.
assert_ok "a recorded deployment proceeds to the zone check" \
  bash -c "podman run --rm -e ULTUS_DEPLOY_TRIES=1 -e ULTUS_HEALTH_TRIES=1 '$img' bash -c \"mkdir -p /run/ultus-corp /var/lib/ultus-corp/deployments && printf '%s\n' $delivered_id > /run/ultus-corp/deployment-id && printf '{}\n' > /var/lib/ultus-corp/deployments/$delivered_id.json && /etc/greenboot/check/required.d/50-dns-health.sh\" 2>&1 | grep -q 'no SOA for lab.internal'"

# A required check must fail when the service it names is absent. Without this,
# a green boot proves nothing: the check would pass on any image. A record marks
# the host as deployed, which is the case the check must judge.
deployed_check() {
  podman run --rm -e ULTUS_HEALTH_TRIES=1 "$img" bash -c \
    'mkdir -p /var/lib/ultus-corp/deployments && : > /var/lib/ultus-corp/deployments/deployed.json && exec /etc/greenboot/check/required.d/50-dns-health.sh'
}
assert_fails "the health check fails with no resolver" deployed_check
out=$(deployed_check 2>&1 || true)
assert_eq "the failure names the zone" "yes" \
  "$(grep -q 'no SOA for lab.internal' <<<"$out" && echo yes || echo no)"

# The throwaway check ships under /usr so a rollback removes it. The marker is
# on /var, which a rollback keeps, so it can prove the failing boot happened.
assert_fails "the broken check fails" \
  podman run --rm -v "$PWD/tests/fixtures/greenboot:/broken:ro" "$img" \
  bash -c 'install -m 0755 /broken/99-broken.sh /tmp/99-broken.sh && /tmp/99-broken.sh'
assert_ok "the broken check leaves its marker" \
  bash -c "podman run --rm -v '$PWD/tests/fixtures/greenboot:/broken:ro' '$img' bash -c 'install -m 0755 /broken/99-broken.sh /tmp/99-broken.sh; /tmp/99-broken.sh || true; test -e /var/lib/ultus-corp/greenboot-broken-proof'"

finish
