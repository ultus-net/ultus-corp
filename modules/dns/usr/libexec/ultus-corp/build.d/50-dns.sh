#!/usr/bin/env bash
set -euo pipefail

for unit in ultus-provision.service ultus-dns-ready.service unbound.service; do
  systemctl enable "$unit"
  systemctl is-enabled --quiet "$unit" || {
    echo "failed to enable $unit" >&2
    exit 1
  }
done

echo "dns module ok"
