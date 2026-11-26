#!/usr/bin/env bash
set -euo pipefail

# dig prints transport errors on stdout, so a non-empty answer proves nothing.
# The reply status is what separates an answer from a refusal.
reply=$(dig +time=2 +tries=1 lab.internal SOA @127.0.0.1 2>&1) || {
  echo "no answer for lab.internal from 127.0.0.1" >&2
  exit 1
}
if ! grep -q 'status: NOERROR' <<< "$reply"; then
  echo "no SOA for lab.internal from 127.0.0.1" >&2
  exit 1
fi
