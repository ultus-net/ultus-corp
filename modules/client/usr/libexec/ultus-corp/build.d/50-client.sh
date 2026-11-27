#!/usr/bin/env bash
set -euo pipefail
rpm -q NetworkManager >/dev/null
test -x /etc/greenboot/check/required.d/50-client-health.sh
# The client applies no configuration, so an applier here would be dead code.
test ! -e /usr/libexec/ultus-corp/provision.sh
echo "client module ok"
