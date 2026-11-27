#!/usr/bin/env bash
set -euo pipefail

# The vendor unit runs inside the multi-user transaction, so it cannot be
# ordered after cloud-init's final stage: cloud-final is itself ordered after
# multi-user, and the ordering cycle deletes the check. The check runs early and
# reads the durable record instead.
#
# A deployment record under /var is the proof this host has been in service. No
# record means the first boot has not been provisioned yet, so there is nothing
# to judge; a delivered id with no record is an unfinished deployment, and
# greenboot must roll it back.
records=/var/lib/ultus-corp/deployments
idfile=/run/ultus-corp/deployment-id
if [ -s "$idfile" ]; then
  id=$(tr -d '[:space:]' < "$idfile")
  case "$id" in
    *[!0-9a-f-]*|"")
      echo "deployment id file does not hold a plain id: $id" >&2
      exit 1
      ;;
  esac
  [ "${#id}" -eq 36 ] || {
    echo "deployment id is not 36 characters: $id" >&2
    exit 1
  }
  record=/var/lib/ultus-corp/deployments/$id.json
  for _ in $(seq "${ULTUS_DEPLOY_TRIES:-120}"); do
    [ -s "$record" ] && break
    sleep 1
  done
  if [ ! -s "$record" ]; then
    echo "deployment $id did not record within ${ULTUS_DEPLOY_TRIES:-120}s" >&2
    exit 1
  fi
elif ! compgen -G "$records/*.json" >/dev/null; then
  echo "no deployment recorded yet; the first boot is not judged"
  exit 0
fi

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
