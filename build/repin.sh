#!/usr/bin/env bash
# Verify the pinned base image against the signer recorded in the repository.
#
# The weekly repin job must prove who built the digest before it opens a PR. An
# incomplete signer file is a refusal, not a default: trusting an unverified
# digest is the failure this gate exists to prevent.
set -euo pipefail

signer_identity() {
  sed -n 's/^identity=//p' "$1" | head -n 1
}

signer_issuer() {
  sed -n 's/^issuer=//p' "$1" | head -n 1
}

verify_ref() {
  local signer=${1:?usage: repin.sh <signer-file> <image-ref>}
  local ref=${2:?usage: repin.sh <signer-file> <image-ref>}
  local identity issuer
  [ -s "$signer" ] || {
    echo "repin: no signer at $signer; refusing to trust $ref" >&2
    return 1
  }
  identity=$(signer_identity "$signer")
  issuer=$(signer_issuer "$signer")
  [ -n "$identity" ] && [ -n "$issuer" ] || {
    echo "repin: $signer records no identity or issuer; refusing to trust $ref" >&2
    return 1
  }
  cosign verify \
    --certificate-identity "$identity" \
    --certificate-oidc-issuer "$issuer" \
    "$ref"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  verify_ref "$@"
fi
