#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
. build/checks.sh

assert_ok    "pinned base accepted"   check_base_pin tests/fixtures/base.expected tests/fixtures/Containerfile.pinned
assert_fails "wrong repository rejected" check_base_pin tests/fixtures/base.expected tests/fixtures/Containerfile.wrong-repo
assert_ok    "one package per line accepted"      check_manifest_one_per_line tests/fixtures/packages-ok.txt
assert_fails "two packages on one line rejected"  check_manifest_one_per_line tests/fixtures/packages-multi.txt
assert_fails "key material in tree rejected"      check_no_secret_patterns tests/fixtures
assert_ok    "clean file accepted"                check_no_secret_patterns tests/fixtures/leak-clean.txt
assert_fails "install media rejected"             check_no_install_media tests/fixtures
assert_ok    "complete role record accepted"      check_role_records tests/fixtures/roles/dns.md
assert_fails "incomplete role record rejected"    check_role_records tests/fixtures/roles/incomplete.md

finish
