#!/usr/bin/env bash
# The deployment contract inside the image: the units, the record and the
# refusals. No hypervisor; the record is written by the applier under test.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/common.sh
img=$(lab_image dns)
digest="sha256:$(printf '1%.0s' $(seq 64))"
id=$(python3 -c 'import uuid; print(uuid.uuid4())')

# The guest scripts live in fixtures so no quoting is hidden in this file. The
# id and digest reach them as environment, and the stub bootc as PATH.
in_image() {
  local script=$1
  podman run --rm -i \
    -e DEPLOY_ID="$id" -e DEPLOY_DIGEST="$digest" \
    -v "$PWD/tests/fixtures:/fixtures:ro" \
    "$img" bash -s < "tests/fixtures/deploy/$script"
}

assert_eq "finalize unit shipped" "present" \
  "$(podman run --rm "$img" test -f '/usr/lib/systemd/system/ultus-deploy-finalize@.service' && echo present)"
assert_eq "role install target shipped" "present" \
  "$(podman run --rm "$img" test -f /usr/lib/systemd/system/ultus-role-install.target && echo present)"
assert_eq "ready target shipped" "present" \
  "$(podman run --rm "$img" test -f /usr/lib/systemd/system/ultus-deploy-ready.target && echo present)"
assert_eq "the applier is enabled" "enabled" \
  "$(podman run --rm "$img" systemctl is-enabled ultus-provision.service)"
assert_ok "the role install target pulls the applier" podman run --rm "$img" \
  test -L /etc/systemd/system/ultus-role-install.target.wants/ultus-provision.service
assert_ok "the applier is ordered before the role install target" podman run --rm "$img" \
  bash -c "grep -q 'Before=.*ultus-role-install.target' '/usr/lib/systemd/system/ultus-provision.service'"
assert_ok "finalize is conditioned on the record" podman run --rm "$img" \
  bash -c "grep -q 'ConditionPathExists=!/var/lib/ultus-corp/deployments/%i.json' '/usr/lib/systemd/system/ultus-deploy-finalize@.service'"
assert_ok "finalize is ordered before the ready target" podman run --rm "$img" \
  bash -c "grep -q 'Before=ultus-deploy-ready.target' '/usr/lib/systemd/system/ultus-deploy-finalize@.service'"
assert_ok "finalize runs after cloud-final" podman run --rm "$img" \
  bash -c "grep -q 'After=cloud-final.service' '/usr/lib/systemd/system/ultus-deploy-finalize@.service'"
assert_ok "the finalize applier is live" podman run --rm "$img" \
  test -x /usr/libexec/ultus-corp/finalize.sh

# One record, the four contract keys, the delivered role and the booted digest.
assert_ok "a deployment is recorded" in_image record.sh
assert_ok "a second run leaves the record alone" in_image idempotent.sh

# The refusals. Each proves its own negative, so a gate that accepts everything
# cannot pass by exiting zero.
assert_ok "an id with a path is refused" in_image refuse-path.sh
assert_ok "a missing deployment id is refused" in_image refuse-missing-id.sh
assert_ok "a mismatched deployment id is refused" in_image refuse-mismatch.sh
assert_ok "a host with no booted image is refused" in_image refuse-unbooted.sh

finish
