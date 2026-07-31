#!/usr/bin/env bash
# Push manifest artifacts to the in-cluster Zot registry and sign each digest
# with the local cosign key. `foundation` excludes every demo artifact.
set -euo pipefail

cd "$(dirname "$0")/.."

mode="${1:-all}"

REGISTRY="${REGISTRY:-localhost:5001/acme}"
COSIGN_KEY="${COSIGN_KEY:-.keys/cosign.key}"
REVISION="local@sha1:$(git rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)"

test -f "${COSIGN_KEY}" || { echo "${COSIGN_KEY} not found; run 'make signing-keys' first"; exit 1; }

kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
trap 'kill ${PORT_FORWARD_PID} 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -fsS "http://localhost:5001/v2/" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://localhost:5001/v2/" >/dev/null

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
    --use-signing-config=false \
    --tlog-upload=false \
    --allow-insecure-registry \
    --registry-referrers-mode=legacy \
    "${REGISTRY}/${repo}@${digest}"
  crane tag --insecure "${REGISTRY}/${repo}@${digest}" latest
  # Fail loudly if the signature did not land on this exact digest. A racey
  # re-push (or a signing error) otherwise leaves `latest` pointing at an
  # unsigned digest that Flux silently refuses to verify — the failure mode
  # that stalled every signalloom OCIRepository. Verify with flags proven to
  # find the legacy referrer signature this push just created.
  COSIGN_PASSWORD="" cosign verify \
    --key "${COSIGN_KEY%.key}.pub" \
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
  run_parallel_push foundation \
    "fleet|d2-osramp-fleet" \
    "infra/cert-manager|d2-infra/components/cert-manager" \
    "infra/ingress|d2-infra/components/ingress" \
    "infra/monitoring|d2-infra/components/monitoring" \
    "infra/trivy-system|d2-infra/components/trivy-system"
}

push_signalloom() {
  run_parallel_push signalloom \
    "signalloom/infra/inf-bao|d2-signalloom/infra/inf-bao" \
    "signalloom/infra/inf-signalloom|d2-signalloom/infra/inf-signalloom" \
    "signalloom/apps/fe-signalloom|d2-signalloom/apps/fe-signalloom"
}

push_osramp() {
  run_parallel_push osramp \
    "apps/frontend|d2-osramp-apps/components/frontend" \
    "apps/backend|d2-osramp-apps/components/backend"
}

push_olly() {
  push_and_sign "olly/olly-replica" "olly-replica/components"
}

case "${mode}" in
  foundation) push_foundation ;;
  signalloom) push_signalloom ;;
  all)
    push_foundation
    push_signalloom
    push_osramp
    push_olly
    ;;
  *)
    echo "usage: $0 [all|foundation|signalloom]" >&2
    exit 64
    ;;
esac

echo "all artifacts pushed and signed"
