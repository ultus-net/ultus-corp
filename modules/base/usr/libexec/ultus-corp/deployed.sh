# The vendor unit runs inside the multi-user transaction, so it cannot be
# ordered after cloud-init's final stage: cloud-final is itself ordered after
# multi-user, and the ordering cycle deletes the check. The check runs early and
# reads the durable record instead.
#
# A deployment record under /var is the proof this host has been in service. No
# record means the first boot has not been provisioned yet, so there is nothing
# to judge; a delivered id with no record is an unfinished deployment, and
# greenboot must roll it back.
#
# Sourced by every role's required check, so it sets no shell options.
deployment_gate() {
  local records=/var/lib/ultus-corp/deployments
  local idfile=/run/ultus-corp/deployment-id
  local id record
  if [ -s "$idfile" ]; then
    id=$(tr -d '[:space:]' < "$idfile")
    # The applier refuses anything that is not a lowercase UUIDv4, so the check
    # uses the same shape. A looser match would accept an id the record path can
    # never hold, and the wait would end in a misleading timeout.
    if [[ ! "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
      echo "deployment id is not a lowercase UUIDv4: $id" >&2
      exit 1
    fi
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
  return 0
}
