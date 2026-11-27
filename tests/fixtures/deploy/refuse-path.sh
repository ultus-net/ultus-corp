#!/usr/bin/env bash
# The id becomes a path, so anything but a plain UUIDv4 must be refused before
# a single byte is written.
set -euo pipefail
mkdir -p /run/ultus-corp
printf '%s\n' '../../../etc/passwd' > /run/ultus-corp/deployment-id
printf '%s\n' '{"role":"dns"}' > /run/ultus-corp/node.json

if PATH=/fixtures:$PATH /usr/libexec/ultus-corp/finalize.sh '../../../etc/passwd'; then
  echo "a path id was accepted"
  exit 1
fi
test ! -e /etc/passwd.json || { echo "a path id wrote outside the record dir"; exit 1; }
