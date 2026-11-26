#!/usr/bin/env bash
set -euo pipefail
rpm -q bootc greenboot >/dev/null
test -f /usr/lib/systemd/system/bootc-fetch-apply-updates.service \
  || test -f /usr/lib/systemd/system/bootc-fetch-apply-updates.timer
echo "base module ok"
