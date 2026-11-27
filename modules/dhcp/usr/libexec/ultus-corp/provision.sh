#!/usr/bin/env bash
# Apply the configuration the deployment delivered.
# Nothing here renders a per-site value: the seed carries the final files.
set -euo pipefail

node=/run/ultus-corp/node.json
kea=/etc/kea/kea-dhcp4.conf
relay=/etc/ultus-corp/dhcp-relay.conf

[ -s "$node" ] || {
  echo "provision: $node is missing; the deployment did not deliver it" >&2
  exit 1
}

profile=$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1])).get("profile") or "")' "$node")

# cloud-init creates these files unconfined, so they inherit the label of their
# parent directory. Kea and dnsmasq are confined, and cannot read them until the
# policy's own types are applied.
case "$profile" in
server)
  [ -s "$kea" ] || {
    echo "provision: $kea is missing; the deployment did not deliver it" >&2
    exit 1
  }
  if [ -e /sys/fs/selinux/enforce ]; then
    restorecon -RF /etc/kea
  fi
  kea-dhcp4 -t "$kea"

  # The vendor unit may have started at boot with the vendor's own
  # configuration. It is enabled for later boots, restarted onto the delivered
  # configuration, and the apply fails if it does not come up. The image tests
  # run this script in a container with no init, so the handoff is skipped there.
  if [ -d /run/systemd/system ]; then
    systemctl enable kea-dhcp4.service
    systemctl restart kea-dhcp4.service
    systemctl is-active --quiet kea-dhcp4.service
  fi
  ;;
relay)
  [ -s "$relay" ] || {
    echo "provision: $relay is missing; the deployment did not deliver it" >&2
    exit 1
  }
  if [ -e /sys/fs/selinux/enforce ]; then
    restorecon -RF /etc/ultus-corp
  fi
  dnsmasq --test --conf-file="$relay"

  if [ -d /run/systemd/system ]; then
    systemctl enable ultus-dhcp-relay.service
    systemctl restart ultus-dhcp-relay.service
    systemctl is-active --quiet ultus-dhcp-relay.service
  fi
  ;;
*)
  echo "provision: profile '$profile' is neither server nor relay" >&2
  exit 1
  ;;
esac
