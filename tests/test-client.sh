#!/usr/bin/env bash
# The client image adds no package and no applier. Its only job is to prove the
# lease its seed asked for.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/common.sh
img=$(lab_image client)

assert_ok "client image exists" podman image exists "$img"
assert_ok "network manager is present" podman run --rm "$img" rpm -q NetworkManager
assert_ok "kea is absent" podman run --rm "$img" bash -c '! rpm -q kea'
assert_ok "dnsmasq is absent" podman run --rm "$img" bash -c '! rpm -q dnsmasq'
assert_ok "the client ships no applier" \
  podman run --rm "$img" test ! -e /usr/libexec/ultus-corp/provision.sh
assert_ok "the client ships the shared provision unit" \
  podman run --rm "$img" test -f /usr/lib/systemd/system/ultus-provision.service
assert_ok "the client does not enable the shared provision unit" \
  podman run --rm "$img" bash -c '! systemctl is-enabled ultus-provision.service'
assert_ok "the client health check is required" \
  podman run --rm "$img" test -x /etc/greenboot/check/required.d/50-client-health.sh

# A first boot has no record and must not be judged.
assert_ok "an unprovisioned first boot is not judged" \
  bash -c "podman run --rm -e ULTUS_DEPLOY_TRIES=1 '$img' /etc/greenboot/check/required.d/50-client-health.sh 2>&1 | grep -q 'first boot is not judged'"

# A deployed client with no lease must fail closed. The identity names the
# branch CIDR, so the check never carries a lab address.
assert_fails "a deployed client with no lease fails" podman run --rm \
  -e ULTUS_DEPLOY_TRIES=1 -e ULTUS_HEALTH_TRIES=1 "$img" bash -c '
    mkdir -p /run/ultus-corp /var/lib/ultus-corp/deployments
    printf "%s\n" "{\"name\":\"client-a\",\"role\":\"client\",\"profile\":null,\"dhcp_interfaces\":[{\"segment\":\"lan\",\"cidr\":\"10.200.10.0/24\"}]}" > /run/ultus-corp/node.json
    : > /var/lib/ultus-corp/deployments/deployed.json
    exec /etc/greenboot/check/required.d/50-client-health.sh
  '
out=$(podman run --rm -e ULTUS_DEPLOY_TRIES=1 -e ULTUS_HEALTH_TRIES=1 "$img" bash -c '
  mkdir -p /run/ultus-corp /var/lib/ultus-corp/deployments
  printf "%s\n" "{\"name\":\"client-a\",\"role\":\"client\",\"profile\":null,\"dhcp_interfaces\":[{\"segment\":\"lan\",\"cidr\":\"10.200.10.0/24\"}]}" > /run/ultus-corp/node.json
  : > /var/lib/ultus-corp/deployments/deployed.json
  exec /etc/greenboot/check/required.d/50-client-health.sh
' 2>&1 || true)
assert_eq "the failure names the DHCP interface" "yes" \
  "$(grep -q 'no DHCP lease' <<<"$out" && echo yes || echo no)"

# A lease inside the identity's CIDR must satisfy the check. The address goes on
# lo, so the case needs no DHCP server and no second interface.
assert_ok "a client holding a lease in the named CIDR passes" podman run --rm \
  --cap-add=NET_ADMIN -e ULTUS_DEPLOY_TRIES=1 -e ULTUS_HEALTH_TRIES=1 "$img" bash -c '
    mkdir -p /run/ultus-corp /var/lib/ultus-corp/deployments
    printf "%s\n" "{\"name\":\"client-a\",\"role\":\"client\",\"profile\":null,\"dhcp_interfaces\":[{\"segment\":\"lan\",\"cidr\":\"10.200.10.0/24\"}]}" > /run/ultus-corp/node.json
    : > /var/lib/ultus-corp/deployments/deployed.json
    ip addr add 10.200.10.150/24 dev lo
    exec /etc/greenboot/check/required.d/50-client-health.sh
  '

# A delivered identity that names no DHCP interface cannot be fixed by waiting,
# so the check must fail at once and name the missing key.
out=$(podman run --rm -e ULTUS_DEPLOY_TRIES=1 -e ULTUS_HEALTH_TRIES=120 "$img" bash -c '
  mkdir -p /run/ultus-corp /var/lib/ultus-corp/deployments
  printf "%s\n" "{\"name\":\"client-a\",\"role\":\"client\",\"profile\":null}" > /run/ultus-corp/node.json
  : > /var/lib/ultus-corp/deployments/deployed.json
  timeout 5 /etc/greenboot/check/required.d/50-client-health.sh
  echo "status=$?"
' 2>&1 || true)
assert_eq "an identity without a DHCP interface fails at once" "yes" \
  "$(grep -q 'the identity at /run/ultus-corp/node.json names no DHCP interface' <<<"$out" \
    && grep -q 'status=1' <<<"$out" && echo yes || echo no)"

run_role_proof() {
  local role=$1 proof
  proof=$(sed -n '/^```proof$/,/^```$/p' "docs/roles/$role.md" | sed '1d;$d')
  [ -n "$proof" ] || { echo "no proof block in docs/roles/$role.md"; return 1; }
  podman run --rm "$(lab_image "$role")" bash -c "$proof"
}

assert_ok "record proof passes" run_role_proof client

finish
