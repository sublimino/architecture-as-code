#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${NETASSERT_CONFIG:-${here}/netassert-signalloom.yaml}"
# shellcheck source=scripts/lib/wait.sh
source "${here}/../../scripts/lib/wait.sh"

fail() {
  printf 'netassert runtime prerequisite failed: %s\n' "$*" >&2
  exit 1
}

command -v kubectl >/dev/null 2>&1 || fail "kubectl is unavailable"
[[ -f "$config" ]] || fail "suite config is absent: $config"
kubectl cluster-info >/dev/null 2>&1 || fail "Kubernetes cluster is unreachable"

for namespace in inf-bao inf-signalloom fe-signalloom fe-signalloom-agents; do
  kubectl get namespace "$namespace" >/dev/null 2>&1 \
    || fail "required namespace is absent: $namespace (deploy Signal Loom first)"
done

agent_pod="$(kubectl get pod -n fe-signalloom-agents -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$agent_pod" ]] || fail "no agent pod exists in fe-signalloom-agents"

if grep -Eqi 'supercred|cardvault|policy-engine' "$config"; then
  kubectl get deployment/cardvault -n inf-signalloom >/dev/null 2>&1 \
    || fail "SuperCred cases require deployment/cardvault; run make demo-signalloom-supercred-1"
  kubectl get pod/agent-cardvault -n fe-signalloom-agents >/dev/null 2>&1 \
    || fail "SuperCred cases require pod/agent-cardvault; run make demo-signalloom-supercred-1"
fi

run_file="$(mktemp "${TMPDIR:-/tmp}/netassert-signalloom.XXXXXX.yaml")"
pf_dir="$(mktemp -d "${TMPDIR:-/tmp}/netassert-port-forward.XXXXXX")"
pf_pid=""
cleanup() {
  [[ -z "$pf_pid" ]] || kill "$pf_pid" >/dev/null 2>&1 || true
  rm -f "$run_file"
  rm -rf "$pf_dir"
}
trap cleanup EXIT INT TERM
sed "s/name: agent-patsy/name: ${agent_pod}/g" "$config" > "$run_file"

if command -v netassert >/dev/null 2>&1; then
  netassert run -f "$run_file" -P 3
  exit $?
fi

kubectl get deployment/netassert-controller -n inf-signalloom >/dev/null 2>&1 \
  || fail "host netassert is absent and deployment/netassert-controller is unavailable"
wait_rollout netassert-controller -n inf-signalloom 30 >/dev/null \
  || fail "host netassert is absent and deployment/netassert-controller is not ready"
kubectl get serviceaccount/netassert-runner -n fe-signalloom >/dev/null 2>&1 \
  || fail "serviceaccount/netassert-runner is absent in fe-signalloom"
kubectl get configmap/netassert-signalloom-config -n fe-signalloom >/dev/null 2>&1 \
  || fail "configmap/netassert-signalloom-config is absent in fe-signalloom"

kubectl port-forward -n inf-signalloom service/netassert-controller 18082:8080 \
  >"$pf_dir/stdout" 2>"$pf_dir/stderr" &
pf_pid=$!
wait_reachable http://127.0.0.1:18082/health 30 >/dev/null 2>&1 \
  || fail "controller health endpoint remained unreachable"
curl -fsS -X POST http://127.0.0.1:18082/scan >/dev/null \
  || fail "controller rejected the fixed Netassert scan"

wait_k8s_exists job netassert-run -n fe-signalloom 30 >/dev/null \
  || fail "controller did not create job/netassert-run"
wait_k8s_ready job netassert-run -n fe-signalloom --for condition=complete 120 >/dev/null \
  || fail "job/netassert-run did not complete successfully"

logs="$(kubectl logs -n fe-signalloom job/netassert-run -c netassert 2>&1)" \
  || fail "cannot read netassert-run Job logs"
printf '%s\n' "$logs"
grep -Eq '^1\.\.[1-9][0-9]*$' <<<"$logs" \
  || fail "Netassert emitted no non-empty TAP plan"
if grep -Eq '^not ok ' <<<"$logs"; then
  fail "Netassert reported failing runtime assertions"
fi
