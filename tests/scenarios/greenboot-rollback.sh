#!/usr/bin/env bash
# Prove greenboot rolls back a deliberately failing image.
#
# The host is deployed from the good dns image. A throwaway image is built from
# it with one failing required check under /usr, loaded into the guest from a raw
# disk, and switched to with bootc. greenboot must reject it and return the host
# to the previous image.
set -euo pipefail
cd "$(dirname "$0")/../.."
. tests/lib.sh
. build/common.sh

lab up s1-dns
addresses=$(python3 - <<'PY'
import json, os
state = json.load(open(os.environ["RUN"] + "/s1-dns/state.json"))
print(state["nodes"]["dns-a"]["address"], state["nodes"]["dns-a"]["deployment_id"])
PY
)
read -r addr id_a <<< "$addresses"
record=/var/lib/ultus-corp/deployments/$id_a.json

guest() {
  ssh -i lab-secrets/id_ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=5 "root@$addr" "$@"
}

digest_of() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["booted"]["image"]["imageDigest"])'
}

manifest_ok() {
  guest 'sha256sum -c -' < run/s1-dns/render/dns-a.managed-files.sha256
}

assert_ok "the good image matches its manifest" manifest_ok
good_digest=$(guest 'bootc status --json --format-version=1' | digest_of)
record_before=$(guest "sha256sum $record")

# The failing layer is a patch on the good image, so a rollback returns to an
# image whose only difference is the check that never belonged there.
dns_id=$(podman image inspect --format '{{.Id}}' "$(lab_image dns)")
cat > run/broken.Containerfile <<EOF
FROM $dns_id
COPY tests/fixtures/greenboot/99-broken.sh /usr/lib/greenboot/check/required.d/99-broken.sh
EOF
assert_ok "the failing image builds" podman build -t localhost/ultus-corp/broken:local \
  -f run/broken.Containerfile .
assert_ok "the failing image loads into the guest's archive" \
  bash -c "podman save -o run/broken.tar localhost/ultus-corp/broken:local && chmod 0644 run/broken.tar"

assert_ok "the archive disk attaches" \
  virsh attach-disk ultus-s1-dns-dns-a "$PWD/run/broken.tar" vdb \
  --live --config --targetbus virtio --sourcetype file
assert_ok "the guest imports the failing image" guest 'podman load -i /dev/vdb'
assert_ok "the candidate is present in the guest" \
  guest 'podman image exists localhost/ultus-corp/broken:local'

# One failed boot is enough: the proof is the rollback, not the retry budget.
assert_ok "the guest rolls back after one failed boot" \
  guest 'sed -i "s/^GREENBOOT_MAX_BOOT_ATTEMPTS=.*/GREENBOOT_MAX_BOOT_ATTEMPTS=1/" /etc/greenboot/greenboot.conf && grep -qx "GREENBOOT_MAX_BOOT_ATTEMPTS=1" /etc/greenboot/greenboot.conf'
assert_ok "the good host accepts the candidate" \
  guest 'bootc switch --transport containers-storage localhost/ultus-corp/broken:local'
guest 'systemctl reboot' || true

# The broken boot may be reachable for a moment; the marker proves the failing
# check ran, and the good digest proves the host came back to the old image.
deadline=$((SECONDS + 1500))
rolled=0
current=""
while [ "$SECONDS" -lt "$deadline" ]; do
  current=$(guest 'bootc status --json --format-version=1' 2>/dev/null | digest_of 2>/dev/null || true)
  if [ "$current" = "$good_digest" ] \
    && guest test -e /var/lib/ultus-corp/greenboot-broken-proof 2>/dev/null; then
    rolled=1
    break
  fi
  sleep 15
done
assert_eq "the failing check ran on the candidate" "1" "$rolled"
assert_eq "the host rolled back to the previous image" "$good_digest" "$current"
assert_ok "the rollback removed the failing check" \
  guest test ! -e /usr/lib/greenboot/check/required.d/99-broken.sh
assert_ok "the previous image matches its manifest after the rollback" manifest_ok
assert_eq "the deployment record is unchanged" "$record_before" \
  "$(guest "sha256sum $record")"
assert_ok "the health check passes on the restored image" \
  guest /etc/greenboot/check/required.d/50-dns-health.sh

lab down s1-dns
assert_ok "no domain left" bash -c "! virsh list --all --name | grep -q ultus-s1-dns"
assert_ok "the archive disk is gone with the domain" \
  bash -c "! virsh domblklist ultus-s1-dns-dns-a 2>/dev/null | grep -q broken.tar"
python3 -c 'import pathlib; [pathlib.Path(p).unlink(missing_ok=True) for p in ("run/broken.tar", "run/broken.Containerfile")]'

finish
