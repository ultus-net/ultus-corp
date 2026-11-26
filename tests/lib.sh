FAILURES=0
_name=${0##*/}
_name=${_name%.sh}
_name=${_name#test-}
EVIDENCE=${EVIDENCE:-run/evidence/$_name.log}
mkdir -p "$(dirname "$EVIDENCE")"
: > "$EVIDENCE"
export LIBVIRT_DEFAULT_URI=${LIBVIRT_DEFAULT_URI:-qemu:///system}
RUN=${LAB_RUN_DIR:-run}
. build/checks.sh

record() {
  local name="$1"
  local status="$2"
  shift 2
  local expected="$1"
  shift
  local observed="$1"
  shift
  observed=${observed//$'\n'/\\n}
  printf '%s|%s|%s|%s|%s\n' "$name" "$status" "$*" "$expected" "$observed" >> "$EVIDENCE"
}

assert_ok() {
  local name="$1"
  shift
  local out
  local status
  out=$("$@" 2>&1) && status=ok || status=fail
  record "$name" "$status" "exit 0" "${out+${out:-no output}}" "$@"
  if [ "$status" = "ok" ]; then echo "ok $name"; else echo "FAIL $name: ${out:-exit $?}"; FAILURES=$((FAILURES+1)); fi
}

assert_fails() {
  local name="$1"
  shift
  local out
  local status
  out=$("$@" 2>&1) && status=ok || status=fail
  record "$name" "$status" "non-zero exit" "${out+${out:-no output}}" "$@"
  if [ "$status" = "ok" ]; then echo "FAIL $name: exited 0"; FAILURES=$((FAILURES+1)); else echo "ok $name (refused: ${out%%$'\n'*})"; fi
}

assert_eq() {
  local name="$1"
  local expected="$2"
  local observed="$3"
  record "$name" "$([ "$expected" = "$observed" ] && echo ok || echo fail)" "$expected" "$observed" "compare"
  if [ "$expected" = "$observed" ]; then echo "ok $name"; else echo "FAIL $name: expected '$expected', observed '$observed'"; FAILURES=$((FAILURES+1)); fi
}

finish() {
  if [ "$FAILURES" -ne 0 ]; then echo "$FAILURES failing"; exit 1; fi
  echo "$_name gate passed"
  echo "evidence: $EVIDENCE"
}
