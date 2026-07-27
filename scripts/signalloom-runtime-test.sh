#!/usr/bin/env bash
# Runtime acceptance for the intentionally bounded local Signal Loom slice.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly repo_root
timeout="${DEMO_WAIT_TIMEOUT:-10m}"
port="${SIGNALLOOM_PORTAL_PORT:-18000}"
forward_pid=""

cleanup() {
  [[ -z "$forward_pid" ]] || kill "$forward_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'required command unavailable: %s\n' "$1" >&2
    exit 1
  }
}

assert_workload_pods_ready() {
  local namespace="$1"
  kubectl -n "$namespace" get pods -o json | jq -e '
    [.items[] | select(any(.metadata.ownerReferences[]?; .kind != "Job"))]
    | length > 0
    and all(.[];
      .status.phase == "Running"
      and all(.status.containerStatuses[]?;
        .ready == true
        and (.state.waiting == null)
        and (.state.terminated == null)))
  ' >/dev/null
}

for command in kubectl curl jq; do require_command "$command"; done

for namespace in inf-signalloom fe-signalloom; do
  kubectl -n "$namespace" get deployment -o name | while read -r deployment; do
    kubectl -n "$namespace" wait "$deployment" --for=condition=available --timeout="$timeout"
  done
  assert_workload_pods_ready "$namespace"
done

"$repo_root/scripts/bao-spire-proof.sh"

kubectl -n fe-signalloom port-forward service/fe-signalloom "$port:8000" >/tmp/signalloom-portal-port-forward.log 2>&1 &
forward_pid="$!"
for _ in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:$port/health" >/tmp/signalloom-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done
grep -Fqx '{"status":"ok"}' /tmp/signalloom-health.json
curl --fail --silent "http://127.0.0.1:$port/readyz" | jq -e '.status == "ready" and .postgresql == "ready"' >/dev/null
printf 'Signal Loom runtime acceptance passed\n'
