#!/usr/bin/env bash
set -euo pipefail
rpm -q bootc greenboot >/dev/null
test -f /usr/lib/systemd/system/bootc-fetch-apply-updates.service \
  || test -f /usr/lib/systemd/system/bootc-fetch-apply-updates.timer

# A required check that never runs proves nothing, so the health check unit
# is enabled here rather than left to the package preset.
systemctl enable greenboot-healthcheck.service
systemctl is-enabled --quiet greenboot-healthcheck.service || {
  echo "failed to enable greenboot-healthcheck.service" >&2
  exit 1
}

echo "base module ok"
