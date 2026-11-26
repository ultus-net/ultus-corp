#!/usr/bin/env bash
set -euo pipefail

answer=$(dig +short +time=2 +tries=1 lab.internal SOA @127.0.0.1)
if [ -z "$answer" ]; then
  echo "no SOA for lab.internal from 127.0.0.1" >&2
  exit 1
fi
