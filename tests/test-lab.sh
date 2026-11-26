#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh

export PATH="$PWD/lab:$PWD/tests/fake:$PATH"
export FAKE_VIRSH_DIR="$PWD/run/fake-virsh"
export LAB_DISK_BUILDER="$PWD/tests/fake/build-disk"

reset() {
  python3 - "$@" <<'PY'
import pathlib, shutil, sys
for name in sys.argv[1:]:
    shutil.rmtree(name, ignore_errors=True)
    pathlib.Path(name).unlink(missing_ok=True)
PY
}

reset run/s0-base run/s1-dns run/fake-virsh

assert_fails "down before up is an error"  lab down s0-base
assert_ok    "up records state"            lab up s0-base
assert_ok    "state is schema 1"           python3 -c 'import json,sys; d=json.load(open("run/s0-base/state.json")); sys.exit(d["schema"] != 1)'
assert_ok    "state names the node"        python3 -c 'import json,sys; d=json.load(open("run/s0-base/state.json")); sys.exit(d["nodes"]["base-a"]["address"] != "10.100.10.20")'
assert_ok    "up is idempotent"            lab up s0-base
assert_ok    "status lists the scenario"   bash -c 'lab status | grep -q s0-base'
assert_ok    "seed is 0700"                bash -c '[ "$(stat -c %a run/s0-base/seed)" = 700 ]'
assert_ok    "seed file is 0600"           bash -c '[ "$(stat -c %a run/s0-base/seed/base-a/meta-data)" = 600 ]'

python3 -c 'import pathlib; pathlib.Path("run/fake-virsh/count").unlink(missing_ok=True)'
assert_fails "failed up exits non-zero"    bash -c 'VIRSH_FAIL_ON=3 lab up s1-dns'
assert_ok    "failed up leaves no domain"  bash -c '! virsh list --all --name | grep -q ultus-s1-dns'
assert_ok    "failed up leaves no state"   bash -c '! test -e run/s1-dns/state.json'

assert_ok    "down removes state"          lab down s0-base
assert_ok    "down removes the seed tree"  bash -c '! test -e run/s0-base/seed'
assert_fails "second down is an error"     lab down s0-base
assert_ok    "up after down succeeds"      lab up s0-base
assert_ok    "prune refuses in-use disk"   bash -c '! lab prune --all'

python3 -c 'import pathlib; pathlib.Path("run/s0-base/state.json").unlink()'
assert_ok    "force down repairs state"    bash -c 'lab down s0-base --force 2>&1 | grep -q warning'
assert_ok    "force down leaves no domain" bash -c '! virsh list --all --name | grep -q ultus-s0-base'
assert_ok    "force down clears state"     bash -c '! test -e run/s0-base/state.json'

mkdir -p build/vm/cache
printf 'cached\n' > build/vm/cache/dns-fakeimageid0.qcow2
assert_ok    "cached disk skips the builder" bash -c 'lab/build-disk.sh dns run/cache-test.qcow2'
assert_eq    "cached disk is copied" "cached" "$(cat run/cache-test.qcow2)"
rm -f build/vm/cache/dns-fakeimageid0.qcow2 run/cache-test.qcow2
assert_fails "rootless podman is refused"    lab/build-disk.sh dns run/no-cache.qcow2

finish
