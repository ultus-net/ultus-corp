#!/usr/bin/env bash
# A required check that always fails. It ships only in the throwaway image the
# rollback proof switches to, under /usr so the rollback removes it. The marker
# is on /var, which survives a rollback, so a green boot after the switch proves
# the failing boot ran rather than that the switch never happened.
set -euo pipefail
mkdir -p /var/lib/ultus-corp
: > /var/lib/ultus-corp/greenboot-broken-proof
echo "broken image: the required check always fails" >&2
exit 1
