#!/usr/bin/env bash
# Trust revocation walkthrough: push an unsigned update of the frontend
# component, watch Flux refuse to reconcile it (verification fails closed,
# the running workload stays on the last good state), then restore trust by
# signing a fixed artifact and watch it promote.
#
# SAFETY INVARIANT
# ----------------
# This script must never terminate leaving an unsigned or unverifiable
# frontend artifact in the shared Zot registry. `apps/frontend:latest` is
# consumed by the OSRAMP slice, so a poisoned tag survives the demo and makes
# the NEXT `make demo-osramp-up` fail verification with no obvious cause.
#
# Two mechanisms uphold that invariant:
#
#   1. preflight() proves restoration is possible BEFORE anything is revoked.
#      Signing material, the artifact source, and the reconcile target are all
#      checked up front. The previous version pushed the unsigned artifact
#      first and only then discovered that ocirepository/apps was missing --
#      under `set -e` it died there, and step 2 (the restore) never ran.
#
#   2. REVOKED is set BEFORE the destructive push, and the EXIT/INT/TERM trap
#      restores whenever it is still set. Restoration is therefore an
#      invariant of leaving the script, not a step that has to be reached.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

REGISTRY="${REGISTRY:-localhost:5001/acme}"
# shellcheck source=scripts/lib/keys.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/keys.sh"
KEYS_DIR="$(keys_dir)"
COSIGN_KEY="${COSIGN_KEY:-${KEYS_DIR}/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-${COSIGN_KEY%.key}.pub}"
SIGNING_CONFIG="${SIGNING_CONFIG:-${COSIGN_KEY%/*}/signing-config.json}"
FRONTEND_PATH="d2-osramp-apps/components/frontend"
REPO="apps/frontend"
ARTIFACT="oci://${REGISTRY}/${REPO}:latest"

REVOKED=0
PORT_FORWARD_PID=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Everything that must hold before the registry is mutated. Anything checked
# here is something whose absence would otherwise strand a revoked artifact.
preflight() {
  local c
  for c in kubectl flux cosign jq; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done

  # Without the signing key we could revoke but never restore.
  [ -f "${COSIGN_KEY}" ] || die "cosign key missing: ${COSIGN_KEY} (run: make signing-keys)"
  [ -f "${COSIGN_PUB}" ] || die "cosign public key missing: ${COSIGN_PUB} (run: make signing-keys)"
  [ -d "${FRONTEND_PATH}" ] || die "artifact source path missing: ${FRONTEND_PATH}"

  # The demo exists to watch Flux refuse the unsigned artifact. Without the
  # OSRAMP frontend slice there is nothing to observe and nothing to restore
  # into -- so refuse rather than poisoning a registry other slices share.
  kubectl -n frontend get ocirepository apps >/dev/null 2>&1 || die \
"OSRAMP frontend slice not deployed (no ocirepository/apps in namespace frontend).
Refusing to push a revoked artifact into the shared registry.
Deploy the slice first:  make demo-osramp-up"

  # Key-only signing config (cosign v3), same idiom as scripts/push-local.sh.
  [ -f "${SIGNING_CONFIG}" ] || cosign signing-config create \
    --no-default-rekor --no-default-fulcio --no-default-oidc --no-default-tsa \
    --out "${SIGNING_CONFIG}" >/dev/null 2>&1 || true
}

# Push the artifact and sign it, then prove the signature landed on that exact
# digest. Mirrors the push/sign/verify sequence in scripts/push-local.sh.
#
# This used to pass --registry-referrers-mode=legacy and claim that omitting it
# left "a signature Flux would not find". Measured against the pinned cosign
# v3.0.6 on 2026-08-13, that is not so: legacy, oci-1-1 and omitting the flag all
# store a key-based signature identically, as one OCI referrer of artifactType
# application/vnd.dev.sigstore.bundle.v0.3+json with no sha256-<digest>.sig tag,
# and Flux source-controller v1.9.4 reads that fine. The flag was inert, and the
# comment asserting otherwise is what sent a later investigation after the
# storage format instead of the signing key. Echoes the digest. Idempotent.
#
# NOTE: the verify below shares the tautology that scripts/push-local.sh now
# guards against -- COSIGN_PUB is the public half of COSIGN_KEY, so this can only
# pass. It proves the signature landed on this digest, not that the cluster will
# accept it. push-local.sh's assert_signing_key_is_trusted covers the trust
# question for every artifact this demo depends on, including this one.
push_signed() {
  local revision="$1" digest
  digest="$(flux push artifact "${ARTIFACT}" \
    --path="${FRONTEND_PATH}" \
    --source=local \
    --revision="${revision}@sha1:$(git rev-parse HEAD 2>/dev/null || printf '%040d' 0)" \
    --insecure-registry --output json 2>/dev/null | jq -r '.digest')" || return 1
  [ -n "${digest}" ] && [ "${digest}" != "null" ] || return 1

  COSIGN_PASSWORD="" cosign sign --yes \
    --key "${COSIGN_KEY}" \
    --signing-config "${SIGNING_CONFIG}" \
    --allow-insecure-registry \
    "${REGISTRY}/${REPO}@${digest}" >/dev/null 2>&1 || return 1

  COSIGN_PASSWORD="" cosign verify \
    --key "${COSIGN_PUB}" \
    --insecure-ignore-tlog=true \
    --allow-insecure-registry \
    "${REGISTRY}/${REPO}@${digest}" >/dev/null 2>&1 || return 1

  printf '%s' "${digest}"
}

# Restoration is attempted on EVERY exit path while REVOKED is set: clean
# failure, unexpected assertion result, or Ctrl-C. Never let a failure inside
# cleanup abort cleanup itself.
cleanup() {
  local rc=$?
  set +e
  if [ "${REVOKED}" -eq 1 ]; then
    printf '\n=== restoring trust before exit (the registry must not be left unsigned)\n'
    if push_signed "restore-on-exit" >/dev/null; then
      REVOKED=0
      echo "registry restored: ${REPO}:latest is signed and verifiable"
    else
      printf 'FATAL: could not restore %s:latest.\n' "${REPO}" >&2
      printf 'The shared registry may hold an UNSIGNED artifact. Restore manually:\n' >&2
      printf '  make push-local\n' >&2
      rc=1
    fi
  fi
  [ -n "${PORT_FORWARD_PID}" ] && kill "${PORT_FORWARD_PID}" 2>/dev/null
  exit "${rc}"
}
# INT/TERM re-enter through EXIT so restoration runs on Ctrl-C too.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

reconcile_frontend() {
  kubectl annotate --overwrite -n frontend ocirepository/apps \
    reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null
  # Injectable so the fake-binary harness in test/revocation-demo.bats does not
  # spend ~90s asleep proving control flow that has nothing to do with timing.
  sleep "${RECONCILE_SETTLE_SECONDS:-10}"
  kubectl -n frontend get ocirepository apps \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{" "}{.message}{end}'
  echo
}

frontend_ready_status() {
  kubectl -n frontend get ocirepository apps \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null
}

preflight

kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
wait_reachable "http://localhost:5001/v2/" 90

echo "=== step 1: revoke trust (push an UNSIGNED frontend artifact)"
# Set BEFORE the push: if the push itself dies half-way the tag may already
# have moved, so the trap must already consider us revoked.
REVOKED=1
flux push artifact "${ARTIFACT}" \
  --path="${FRONTEND_PATH}" \
  --source=local --revision="revoked@sha1:0000000000000000000000000000000000000000" \
  --insecure-registry >/dev/null
echo "unsigned artifact pushed; asking Flux to reconcile"
reconcile_frontend
if frontend_ready_status | grep -q False; then
  echo "BLOCKED: Flux rejected the unsigned artifact; the workload stays on the last verified state"
else
  # The trap restores on the way out, so this no longer strands the registry.
  die "unexpected: the unsigned artifact was accepted -- image verification is not failing closed"
fi

echo
echo "=== step 2: restore trust (push and SIGN a fixed artifact)"
digest="$(push_signed restored)" \
  || die "failed to push and sign the restored artifact"
echo "signed artifact pushed (${digest}); asking Flux to reconcile"
# Restored and verified above, so the trap no longer needs to act. Clearing it
# here rather than at the end means a failure in the reconcile assertion below
# does not trigger a redundant second restore.
REVOKED=0
reconcile_frontend
if frontend_ready_status | grep -q True; then
  echo "RESTORED: signed artifact verified and reconciled to the cluster"
else
  die "artifact still not verified; inspect: kubectl -n frontend describe ocirepository apps"
fi

echo
echo "revocation walkthrough complete: unsigned blocked, signed promoted"
