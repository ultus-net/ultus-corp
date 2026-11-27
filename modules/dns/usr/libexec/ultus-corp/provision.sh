#!/usr/bin/env bash
# Apply the configuration the deployment delivered.
# Nothing here renders a per-site value: the seed carries the final files.
set -euo pipefail

node=/run/ultus-corp/node.json
conf=/etc/named.conf
resolver=/etc/unbound/unbound.conf
zone=/var/named/lab.internal.zone

for file in "$node" "$conf" "$resolver"; do
  [ -s "$file" ] || {
    echo "provision: $file is missing; the deployment did not deliver it" >&2
    exit 1
  }
done

primary=$(python3 -c 'import json,sys; print("1" if json.load(open(sys.argv[1]))["primary"] else "")' "$node")

# A secondary receives no zone, and a file left by an earlier deployment would
# carry the primary's serial, so BIND would serve it instead of transferring.
if [ -z "$primary" ]; then
  rm -f "$zone" "$zone.jnl"
fi

# cloud-init creates these files unconfined, so they inherit the label of their
# parent directory. named and unbound are confined, and cannot read them until
# the policy's own types are applied.
if [ -e /sys/fs/selinux/enforce ]; then
  restorecon -RF "$conf" /etc/unbound /var/named
fi

named-checkconf "$conf"
if [ -n "$primary" ]; then
  named-checkconf -z "$conf"
fi
unbound-checkconf "$resolver"

# The vendor units may have started at boot with the vendor's own configuration.
# They are enabled for later boots, restarted onto the delivered configuration,
# and the apply fails if either does not come up serving it. The image tests run
# this script in a container with no init, so the handoff is skipped there.
if [ -d /run/systemd/system ]; then
  systemctl enable named.service unbound.service
  systemctl restart named.service unbound.service
  systemctl is-active --quiet named.service
  systemctl is-active --quiet unbound.service
fi
