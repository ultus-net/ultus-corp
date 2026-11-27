#!/usr/bin/env bash
set -euo pipefail

. /usr/libexec/ultus-corp/deployed.sh
deployment_gate

# A secondary holds no zone until its transfer completes, and the check runs
# early in boot, so it retries for half a minute before calling the node bad.
# dig prints transport errors on stdout, so the reply status is what is read,
# never whether the output is non-empty.
for _ in $(seq "${ULTUS_HEALTH_TRIES:-30}"); do
  if reply=$(dig +time=2 +tries=1 lab.internal SOA @127.0.0.1 2>&1) \
    && grep -q 'status: NOERROR' <<< "$reply"; then
    exit 0
  fi
  sleep 1
done

echo "no SOA for lab.internal from 127.0.0.1 after ${ULTUS_HEALTH_TRIES:-30}s" >&2
exit 1
