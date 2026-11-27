#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/checks.sh

assert_ok    "pinned base accepted"   check_base_pin tests/fixtures/base.expected tests/fixtures/Containerfile.pinned
assert_fails "wrong repository rejected" check_base_pin tests/fixtures/base.expected tests/fixtures/Containerfile.wrong-repo
assert_ok    "core froms the pinned base" check_base_pin tests/fixtures/base.expected tests/fixtures/Containerfile.core
assert_ok    "core froms the real pinned base" check_base_pin manifests/base.txt Containerfile.core
assert_ok    "role froms the core"     check_role_froms_core tests/fixtures/Containerfile.role-from-core
assert_fails "role froms the base rejected" check_role_froms_core tests/fixtures/Containerfile.role-from-base
assert_ok    "real role froms the core" check_role_froms_core Containerfile.dns
assert_ok    "digest-pinned core ref accepted" check_core_ref tests/fixtures/core-ref.pinned
assert_fails "tag-only core ref rejected"      check_core_ref tests/fixtures/core-ref-tag.txt
assert_ok    "core build passes the pinned base" check_core_build_arg build/common.sh
assert_fails "unpinned core build rejected"      check_core_build_arg tests/fixtures/build-common-unpinned.sh
assert_fails "core build on the wrong pin rejected" \
  check_core_build_arg tests/fixtures/build-common-wrong-ref.sh

# The core cache key must cover every input the Containerfile copies, or an
# edited base module would ship inside an image that was never rebuilt.
core_key_changes_with_modules() {
  local tmp before after
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ultus-core-key.XXXXXX")
  mkdir -p "$tmp/manifests" "$tmp/build/out" "$tmp/modules/base"
  cp Containerfile.core "$tmp/"
  printf 'pinned\n' > "$tmp/manifests/base.txt"
  printf 'cloud-init\n' > "$tmp/build/out/packages-core.txt"
  printf 'x\n' > "$tmp/modules/base/00-base.sh"
  sed -n '/^core_inputs()/,/^}/p' build/common.sh > "$tmp/key.sh"
  before=$(cd "$tmp" && bash -c '. ./key.sh; core_inputs')
  printf 'y\n' > "$tmp/modules/base/00-base.sh"
  after=$(cd "$tmp" && bash -c '. ./key.sh; core_inputs')
  python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$tmp"
  [ -n "$before" ] && [ "$before" != "$after" ]
}
assert_ok "core cache key covers the base modules" core_key_changes_with_modules
assert_ok    "one package per line accepted"      check_manifest_one_per_line tests/fixtures/packages-ok.txt
assert_fails "two packages on one line rejected"  check_manifest_one_per_line tests/fixtures/packages-multi.txt
assert_fails "key material in tree rejected"      check_no_secret_patterns tests/fixtures
assert_ok    "clean file accepted"                check_no_secret_patterns tests/fixtures/leak-clean.txt
assert_fails "install media rejected"             check_no_install_media tests/fixtures
assert_ok    "complete role record accepted"      check_role_records tests/fixtures/roles/dns.md
assert_fails "incomplete role record rejected"    check_role_records tests/fixtures/roles/incomplete.md

finish
