#!/usr/bin/env bash
# The CI contract, checked without GitHub: the jobs, the digest-scoped signing
# and the repin refusal. A workflow that only looks right is not evidence, so
# the repin check is executed here with a stub cosign.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh

ci=.github/workflows/ci.yml
repin=.github/workflows/repin-base.yml

grep_ci() { grep -q "$1" "$ci"; }
grep_repin() { grep -q "$1" "$repin"; }

assert_ok "ci workflow ships" test -s "$ci"
assert_ok "core job writes the core ref" grep_ci 'manifests/core.txt'
assert_ok "build needs the core job" grep_ci 'needs: core'
assert_ok "the build can push packages" grep_ci 'packages: write'
assert_ok "the build pushes to the org registry" grep_ci 'ghcr.io/ultus-net'
assert_ok "the role build names the core digest" grep_ci 'build-arg CORE'
assert_ok "supply needs the build" grep_ci 'needs: build'
assert_ok "trivy fails on a critical finding" grep_ci 'exit-code: "1"'
assert_ok "trivy scans for critical findings" grep_ci 'severity: CRITICAL'
# A tag that does not exist fails the job before any step runs, as 0.28.0 did.
assert_ok "trivy is pinned to a release" \
  bash -c "grep -qE 'aquasecurity/trivy-action@v?[0-9]+\\.[0-9]+\\.[0-9]+' '$ci'"
assert_ok "the supply job authenticates before it scans" \
  bash -c "awk '/--authfile/{a=NR} /trivy-action/{t=NR} END{exit !(a && t && a < t)}' '$ci'"
assert_ok "the signed digest comes from the pulled image" grep_ci 'RepoDigests'
assert_ok "an SBOM is produced" grep_ci 'sbom.spdx.json'
assert_ok "cosign signs a digest" bash -c "grep -q 'cosign sign --yes' '$ci' && grep -q '@\$DIGEST' '$ci'"

assert_ok "repin workflow ships" test -s "$repin"
assert_ok "repin verifies with an identity" grep_repin 'repin.sh manifests/base.signer'
assert_ok "repin signs nothing before it verifies" \
  bash -c "awk '/repin.sh manifests\\/base.signer/{v=NR} /create-pull-request/{p=NR} END{exit !(v && p && v < p)}' '$repin'"
assert_ok "repin opens a PR only after a verified change" grep_repin "if: env.CHANGED == 'true'"
assert_ok "dependabot tracks actions" test -s .github/dependabot.yml

# The refusal is the point: no signer, or an incomplete one, must not trust the
# digest. A stub cosign logs the call so the flags are proven too.
tmp=$(mktemp -d)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$tmp"' EXIT
log=$tmp/cosign.log
cat > "$tmp/cosign" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
EOF
chmod 0755 "$tmp/cosign"
export PATH="$tmp:$PATH"

. build/repin.sh

assert_fails "a missing signer is refused" verify_ref "$tmp/none.signer" "quay.io/x@sha256:1"
: > "$tmp/empty.signer"
assert_fails "an empty signer file is refused" verify_ref "$tmp/empty.signer" "quay.io/x@sha256:1"
printf 'identity=\nissuer=https://issuer\n' > "$tmp/half.signer"
assert_fails "a signer with no identity is refused" verify_ref "$tmp/half.signer" "quay.io/x@sha256:1"
assert_ok "a refusal never calls cosign" bash -c "! test -e '$log'"

printf 'identity=https://example.test/workflow@refs/heads/main\nissuer=https://token.example.test\n' \
  > "$tmp/good.signer"
assert_ok "a complete signer is verified" \
  verify_ref "$tmp/good.signer" "quay.io/x@sha256:1111"
assert_ok "the identity reaches cosign" grep -q '^verify --certificate-identity https://example.test/workflow@refs/heads/main' "$log"
assert_ok "the issuer reaches cosign" grep -q -- '--certificate-oidc-issuer https://token.example.test' "$log"
assert_ok "the digest reaches cosign" grep -q 'quay.io/x@sha256:1111' "$log"

if command -v actionlint >/dev/null; then
  assert_ok "actionlint accepts the workflows" actionlint
fi

finish
