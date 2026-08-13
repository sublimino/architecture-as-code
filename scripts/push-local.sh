#!/usr/bin/env bash
# Push manifest artifacts to the in-cluster Zot registry and sign each digest
# with the local cosign key. `foundation` excludes every demo artifact.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

mode="${1:-all}"
ENABLE_OBSERVABILITY="${ENABLE_OBSERVABILITY:-true}"

REGISTRY="${REGISTRY:-localhost:5001/acme}"
COSIGN_KEY="${COSIGN_KEY:-.keys/cosign.key}"
REVISION="local@sha1:$(git rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)"

test -f "${COSIGN_KEY}" || { echo "${COSIGN_KEY} not found; run 'make signing-keys' first"; exit 1; }

# A no-transparency-log signing config replaces the deprecated --tlog-upload=false
# flag (cosign v3). Empty rekor/tsa services => key-only signing, no tlog upload.
SIGNING_CONFIG="${SIGNING_CONFIG:-${COSIGN_KEY%/*}/signing-config.json}"
[ -f "${SIGNING_CONFIG}" ] || cosign signing-config create \
  --no-default-rekor --no-default-fulcio --no-default-oidc --no-default-tsa \
  --out "${SIGNING_CONFIG}" >/dev/null 2>&1

kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
TEMP_FLEET_DIR=""
TRUSTED_PUB=""

cleanup() {
  kill "${PORT_FORWARD_PID}" 2>/dev/null || true
  if [[ -n "${TEMP_FLEET_DIR}" ]]; then
    rm -rf "${TEMP_FLEET_DIR}"
  fi
  if [[ -n "${TRUSTED_PUB}" ]]; then
    rm -f "${TRUSTED_PUB}"
  fi
}
trap cleanup EXIT

# The key the CLUSTER trusts, which is the only opinion that decides whether a
# push is usable. Written to a temp file because `cosign verify --key` takes a
# path. Empty when there is no cluster to ask.
TRUSTED_PUB="$(mktemp)"
if ! kubectl -n flux-system get secret cosign-pub \
     -o jsonpath='{.data.cosign\.pub}' 2>/dev/null | base64 -d > "${TRUSTED_PUB}" \
   || ! [ -s "${TRUSTED_PUB}" ]; then
  rm -f "${TRUSTED_PUB}"
  TRUSTED_PUB=""
fi

# Refuse to touch the shared registry with a key the cluster will not accept.
#
# `.keys/` is gitignored, so it is per-checkout, while the kind cluster and the
# zot registry are shared across every checkout and worktree. `make signing-keys`
# is idempotent WITHIN a checkout but generates a fresh keypair for each new one.
# So bootstrapping the cluster from one worktree and pushing from another signs
# artifacts with a key nothing in the cluster trusts.
#
# That failure is expensive to read because cosign reports a signature made by an
# untrusted key with the same words it uses for an artifact that was never signed:
# "no matching signatures were found". On 2026-08-13 that sent an investigation
# after the signature STORAGE FORMAT — referrers vs legacy `.sig` tags — while the
# artifact was signed correctly all along, just by the wrong key.
#
# This runs before the first push on purpose. Discovering the mismatch afterwards
# means the shared registry already holds an artifact the cluster refuses, and
# `crane tag ... latest` has already moved `latest` onto it — which is precisely
# how ocirepository/flux-system got pinned to a stale revision.
assert_signing_key_is_trusted() {
  local local_pub="${COSIGN_KEY%.key}.pub"

  if [[ -z "${TRUSTED_PUB}" ]]; then
    echo "note: no flux-system/cosign-pub secret readable; skipping trust preflight" >&2
    return 0
  fi
  if [[ ! -f "${local_pub}" ]]; then
    echo "FATAL: ${local_pub} not found; run 'make signing-keys' first" >&2
    return 1
  fi

  if ! diff -q "${TRUSTED_PUB}" "${local_pub}" >/dev/null 2>&1; then
    cat >&2 <<EOF
FATAL: refusing to push. This checkout's signing key is not the key the cluster trusts.

  cluster flux-system/cosign-pub : $(sha256sum < "${TRUSTED_PUB}" | cut -c1-16)
  local  ${local_pub} : $(sha256sum < "${local_pub}" | cut -c1-16)

Everything signed with the local key would be rejected by Flux as
"no matching signatures were found", which reads as unsigned rather than
as signed-by-the-wrong-key.

.keys/ is gitignored and therefore per-checkout, so the cluster was almost
certainly bootstrapped from a different checkout or worktree. Either:

  * copy that checkout's .keys/cosign.{key,pub} into this one, or
  * re-point the cluster at this key and re-push every artifact:
      kubectl -n flux-system create secret generic cosign-pub \\
        --from-file=cosign.pub=${local_pub} --dry-run=client -o yaml | kubectl apply -f -
EOF
    return 1
  fi
}

wait_reachable "http://localhost:5001/v2/" 90

push_and_sign() {
  local repo="$1" path="$2"
  echo "pushing oci://${REGISTRY}/${repo}:staging from ${path}"
  local digest
  digest=$(flux push artifact "oci://${REGISTRY}/${repo}:staging" \
    --path="${path}" \
    --source="local" \
    --revision="${REVISION}" \
    --insecure-registry \
    --output json | jq -r '.digest')
  COSIGN_PASSWORD="" cosign sign --yes \
    --key "${COSIGN_KEY}" \
    --signing-config "${SIGNING_CONFIG}" \
    --allow-insecure-registry \
    "${REGISTRY}/${repo}@${digest}"
  crane tag --insecure "${REGISTRY}/${repo}@${digest}" latest

  # Fail loudly if the signature did not land on this exact digest, or landed in
  # a form or under a key the cluster will not accept.
  #
  # This deliberately verifies with the CLUSTER's public key rather than
  # "${COSIGN_KEY%.key}.pub". Verifying with the public half of the key we just
  # signed with is unfalsifiable — it can only pass, so it certifies nothing
  # about the consumer. That tautology is why this script printed "all artifacts
  # pushed and signed" while ocirepository/flux-system sat at Ready=False.
  #
  # When no cluster is reachable the local pub key is the only reference
  # available, so it is still worth asserting the signature exists on this
  # digest; the trust question is simply deferred to the preflight above.
  local verify_key="${TRUSTED_PUB:-${COSIGN_KEY%.key}.pub}"
  COSIGN_PASSWORD="" cosign verify \
    --key "${verify_key}" \
    --insecure-ignore-tlog=true \
    --allow-insecure-registry \
    "${REGISTRY}/${repo}@${digest}" >/dev/null \
    || { echo "FATAL: cosign signature verification failed for ${repo}@${digest}" >&2; exit 1; }
}

wait_for_parallel_push_slot() {
  local -n _wp_pids="$1"
  local -n _wp_components="$2"
  local -n _wp_failures="$3"
  local pid="${_wp_pids[0]}"
  local component="${_wp_components[0]}"

  _wp_pids=("${_wp_pids[@]:1}")
  _wp_components=("${_wp_components[@]:1}")

  if ! wait "$pid"; then
    echo "FATAL: push failed for ${component}" >&2
    _wp_failures+=("$component")
  fi
}

drain_parallel_pushes() {
  local -n pids_ref="$1"
  local -n components_ref="$2"
  local -n failures_ref="$3"

  while ((${#pids_ref[@]} > 0)); do
    wait_for_parallel_push_slot pids_ref components_ref failures_ref
  done
}

run_parallel_push() {
  local group="$1"
  shift

  local max_parallel=4
  local -a active_pids=()
  local -a active_components=()
  local -a failures=()
  local entry repo path

  for entry in "$@"; do
    IFS='|' read -r repo path <<<"$entry"
    push_and_sign "$repo" "$path" &
    active_pids+=("$!")
    active_components+=("$repo")

    if ((${#active_pids[@]} >= max_parallel)); then
      wait_for_parallel_push_slot active_pids active_components failures
    fi
  done

  drain_parallel_pushes active_pids active_components failures

  if ((${#failures[@]} > 0)); then
    echo "FATAL: ${group} push failed for component(s): ${failures[*]}" >&2
    return 1
  fi
}

push_foundation() {
  local fleet_path="d2-osramp-fleet"
  local -a artifacts=(
    "infra/cert-manager|d2-infra/components/cert-manager"
    "infra/ingress|d2-infra/components/ingress"
  )

  case "${ENABLE_OBSERVABILITY}" in
    true)
      artifacts+=(
        "infra/monitoring|d2-infra/components/monitoring"
        "infra/trivy-system|d2-infra/components/trivy-system"
      )
      ;;
    false)
      TEMP_FLEET_DIR="$(mktemp -d)"
      cp -a d2-osramp-fleet/. "${TEMP_FLEET_DIR}"
      fleet_path="${TEMP_FLEET_DIR}"
      sed -i '/    - tenant: "monitoring"/,/      artifactSubjectGitRef: "${ARTIFACT_SUBJECT_GIT_REF}"/d' "${fleet_path}/tenants/base/infra.yaml"
      sed -i '/    - tenant: "trivy-system"/,/      artifactSubjectGitRef: "${ARTIFACT_SUBJECT_GIT_REF}"/d' "${fleet_path}/tenants/base/infra.yaml"
      ;;
    *)
      echo "ENABLE_OBSERVABILITY must be true or false" >&2
      return 64
      ;;
  esac

  push_fleet "$fleet_path"
  run_parallel_push foundation "${artifacts[@]}"
}

push_fleet() {
  push_and_sign "fleet" "${1:-d2-osramp-fleet}"
}

push_agent_trust() {
  push_and_sign "signalloom/agent-trust" "d2-agent-trust/manifests"
}

push_signalloom() {
  run_parallel_push signalloom \
    "signalloom/infra/inf-bao|d2-signalloom/infra/inf-bao" \
    "signalloom/infra/inf-signalloom|d2-signalloom/infra/inf-signalloom" \
    "signalloom/apps/fe-signalloom|d2-signalloom/apps"
}

push_osramp() {
  run_parallel_push osramp \
    "apps/frontend|d2-osramp-apps/components/frontend" \
    "apps/backend|d2-osramp-apps/components/backend"
}

push_olly() {
  push_and_sign "olly/olly-replica" "olly-replica/components"
}

assert_signing_key_is_trusted

case "${mode}" in
  fleet) push_fleet ;;
  agent-trust) push_agent_trust ;;
  foundation) push_foundation ;;
  signalloom) push_signalloom ;;
  all)
    push_foundation
    push_signalloom
    push_agent_trust
    push_osramp
    push_olly
    ;;
  *)
    echo "usage: $0 [all|foundation|fleet|signalloom|agent-trust]" >&2
    exit 64
    ;;
esac

echo "all artifacts pushed and signed"
