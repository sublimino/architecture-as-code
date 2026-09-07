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

validate_tap_file() {
  local tap_file="$1" detail
  if ! detail="$(awk '
    function reject(message) { if (problem == "") problem = message }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (tolower(line) ~ /^bail out!/) reject("bailout record present")
      if (line ~ /^1\.\.[0-9]+([[:space:]]*#.*)?$/) {
        plan_count++
        plan = line
        sub(/^1\.\./, "", plan)
        sub(/[[:space:]#].*$/, "", plan)
        plan += 0
        if (plan < 1) reject("plan must contain at least one test")
        next
      }
      if (line ~ /^(not )?ok[[:space:]]+[0-9]+([[:space:]-]|$)/) {
        failed = (line ~ /^not ok/)
        result = line
        sub(/^not /, "", result)
        split(result, fields, /[[:space:]]+/)
        number = fields[2] + 0
        result_count++
        if (seen[number]++) reject("duplicate numbered result")
        if (failed) reject("failing test result present")
      }
    }
    END {
      if (plan_count != 1) reject("exactly one plan is required")
      if (result_count != plan) reject("numbered result count does not match plan")
      for (number = 1; number <= plan; number++) {
        if (seen[number] != 1) reject("numbered results are incomplete")
      }
      for (number in seen) {
        if (number < 1 || number > plan) reject("numbered result is outside plan")
      }
      if (problem != "") {
        print problem
        exit 1
      }
    }
  ' "$tap_file")"; then
    fail "invalid Netassert TAP: $detail"
  fi
}

if [[ "${1:-}" == "--validate-tap" ]]; then
  [[ $# -eq 2 && -f "$2" ]] || fail "--validate-tap requires one readable file"
  validate_tap_file "$2"
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || fail "kubectl is unavailable"
command -v yq >/dev/null 2>&1 || fail "yq is unavailable"
[[ -f "$config" ]] || fail "suite config is absent: $config"
kubectl cluster-info >/dev/null 2>&1 || fail "Kubernetes cluster is unreachable"

preflight_suite_resources() {
  local side kind name namespace resolved resources
  if ! resources="$(yq e -r '.[]
    | (["source", .src.k8sResource.kind, .src.k8sResource.name, .src.k8sResource.namespace],
       ["destination", .dst.k8sResource.kind, .dst.k8sResource.name, .dst.k8sResource.namespace])
    | @tsv' "$config")"; then
    fail "suite Kubernetes resources cannot be parsed: $config"
  fi
  [[ -n "$resources" ]] || fail "suite contains no Kubernetes resources: $config"
  while IFS=$'\t' read -r side kind name namespace; do
    [[ -n "$kind" && -n "$name" && -n "$namespace" ]] \
      || fail "suite contains an incomplete ${side} Kubernetes resource"
    if [[ "$side" == "source" && "$kind" == "pod" && "$name" == "agent-patsy" ]]; then
      resolved="$(kubectl get pods -n "$namespace" -l signalloom.ai/agent=true -o name 2>/dev/null || true)"
      [[ -n "$resolved" ]] \
        || fail "configured source resource is absent: labeled agent pod in $namespace"
      continue
    fi
    if [[ "$side" == "source" && "$kind" == "pod" && "$name" == "netassert-cardvault-probe-pod" ]]; then
      kubectl get "pod/${name}" -n "$namespace" >/dev/null 2>&1 \
        || fail "parent-provisioned sustained source is absent: pod/${name} in ${namespace}"
      continue
    fi
    kubectl get "${kind}/${name}" -n "$namespace" >/dev/null 2>&1 \
      || fail "configured ${side} resource is absent: ${kind}/${name} in ${namespace}"
  done <<<"$resources"
}

preflight_suite_resources

if [[ "${1:-}" == "--preflight-only" ]]; then
  [[ $# -eq 1 ]] || fail "--preflight-only accepts no additional arguments"
  exit 0
fi

pf_dir="$(mktemp -d "${TMPDIR:-/tmp}/netassert-port-forward.XXXXXX")"
tap_file="$(mktemp "${TMPDIR:-/tmp}/netassert-results.XXXXXX.tap")"
pf_pid=""
cleanup() {
  [[ -z "$pf_pid" ]] || kill "$pf_pid" >/dev/null 2>&1 || true
  rm -f "$tap_file"
  rm -rf "$pf_dir"
}
trap cleanup EXIT INT TERM

kubectl get deployment/netassert-controller -n inf-signalloom >/dev/null 2>&1 \
  || fail "deployment/netassert-controller is unavailable"
wait_rollout netassert-controller -n inf-signalloom 30 >/dev/null \
  || fail "deployment/netassert-controller is not ready"
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
[[ "$logs" == *"===NETASSERT_TAP==="* ]] \
  || fail "netassert-run logs contain no TAP marker"
printf '%s\n' "${logs#*===NETASSERT_TAP===}" >"$tap_file"
validate_tap_file "$tap_file"
