#!/usr/bin/env bash
# A relay forwards a packet between two networks, and the kernel only does that
# with ip_forward on. The unit runs this before dnsmasq starts, so a host that
# cannot enable forwarding fails the start instead of silently dropping packets.
set -euo pipefail

sysctl -w net.ipv4.ip_forward=1 >/dev/null
value=$(cat /proc/sys/net/ipv4/ip_forward)
[ "$value" = 1 ] || {
  echo "relay-prepare: net.ipv4.ip_forward is $value, not 1" >&2
  exit 1
}
