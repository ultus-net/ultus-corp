#!/usr/bin/env bash
set -euo pipefail
rpm -q kea dnsmasq >/dev/null
test -x /usr/libexec/ultus-corp/provision.sh
test -x /usr/libexec/ultus-corp/relay-prepare.sh

# The kea package ships a sample server config at the path Kea reads when it is
# given none. A deployment that delivered no config would then serve that file,
# so the image must carry none.
vendor_kea_conf=/etc/kea/kea-dhcp4.conf
if [ -e "$vendor_kea_conf" ]; then
  rm "$vendor_kea_conf"
fi

# The applier is the only starter. A vendor unit that starts before the seed is
# applied reads an absent configuration and marks the boot degraded.
systemctl disable kea-dhcp4.service dnsmasq.service >/dev/null 2>&1 || true

systemctl enable ultus-provision.service
systemctl is-enabled --quiet ultus-provision.service || {
  echo "failed to enable ultus-provision.service" >&2
  exit 1
}

echo "dhcp module ok"
