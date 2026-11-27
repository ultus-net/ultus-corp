#!/usr/bin/env bash
set -euo pipefail

test -x /usr/libexec/ultus-corp/provision.sh

# The applier is pulled in by the role install target. named and unbound are
# started by the applier after it has written their configuration, so they are
# not enabled here.
for unit in ultus-provision.service ultus-dns-ready.service; do
  systemctl enable "$unit"
  systemctl is-enabled --quiet "$unit" || {
    echo "failed to enable $unit" >&2
    exit 1
  }
done

echo "dns module ok"
