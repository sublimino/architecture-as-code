#!/usr/bin/env bats
# test/kagent-install.bats — Kagent control-plane installation verification.
#
# SCOPE. This file asserts that the control plane is INSTALLED and SCHEDULABLE.
# It deliberately does not — and cannot — assert that the installed components
# do anything: a sleeping container satisfies every readiness gate here. That is
# what test/kagent-anti-stub.bats is for. Read the two together; neither is
# sufficient alone.
#
# WORKLOADS ARE RESOLVED BY ROLE, NOT BY NAME. The upstream Helm chart names
# these differently from the placeholder manifests it replaced —
# kagent-tool-server became kagent-tools, kagent-postgres became
# kagent-postgresql. Hardcoded names turn a successful upgrade into a wall of
# red that reads like a broken install, so each workload is discovered by a name
# pattern and a miss is reported as "no workload matching <role>" rather than as
# a failed assertion about a name nobody uses any more.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
  NS="kagent"
}

# Name of the single Deployment in $NS whose name matches a role pattern.
# Empty output means "not found"; every caller treats that as a failure.
find_deploy() {
  kubectl get deploy -n "${NS}" -o json |
    jq -r --arg re "$1" '[ .items[] | select(.metadata.name | test($re; "i")) ][0].metadata.name // empty'
}

require_deploy() {
  local role="$1" pattern="$2" name
  name="$(find_deploy "$pattern")"
  [ -n "$name" ] || {
    echo "no Deployment in ${NS} matching the ${role} pattern /${pattern}/"
    kubectl get deploy -n "${NS}"
    return 1
  }
  printf '%s' "$name"
}

# A Service with no ready endpoint is a name that resolves to nothing. Callers
# get "connection refused" rather than a DNS error, so a Service can look
# installed while nothing is behind it.
ready_endpoint_count() {
  kubectl get endpointslice -n "${NS}" \
    -l "kubernetes.io/service-name=$1" -o json 2>/dev/null |
    jq '[ .items[]?.endpoints[]? | select(.conditions.ready == true) ] | length'
}

assert_ready_with_endpoint() {
  local role="$1" pattern="$2"
  local name
  name="$(require_deploy "$role" "$pattern")"

  local ready
  ready="$(kubectl get deployment "$name" -n "${NS}" -o jsonpath='{.status.readyReplicas}')"
  [ "${ready:-0}" -ge 1 ] || {
    echo "Deployment ${name} has ${ready:-0} ready replicas"
    return 1
  }

  # The Service is conventionally named after the Deployment in both the
  # placeholder manifests and the upstream chart.
  local eps
  eps="$(ready_endpoint_count "$name")"
  [ "${eps:-0}" -ge 1 ] || {
    echo "Service ${name} has ${eps:-0} ready endpoints — the name resolves to nothing"
    kubectl get endpointslice -n "${NS}" -l "kubernetes.io/service-name=${name}"
    return 1
  }
}

@test "kagent: CustomResourceDefinitions are registered in cluster" {
  for crd in agents.kagent.dev modelconfigs.kagent.dev remotemcpservers.kagent.dev; do
    run kubectl get crd "$crd"
    [ "$status" -eq 0 ]
  done
}

@test "kagent: Agent CRD serves v1alpha2 and exposes a status subresource" {
  # The precondition that makes reconciliation observable at all. A CRD without
  # a status subresource cannot record that a controller ever looked at the
  # object, which would make the reconciliation assertion in
  # test/kagent-anti-stub.bats unsatisfiable however real the controller is.
  # Asserting it here means that failure is diagnosed as a schema problem rather
  # than misread as a dead controller.
  run kubectl get crd agents.kagent.dev -o json
  [ "$status" -eq 0 ]

  served="$(printf '%s' "$output" | jq -r '[ .spec.versions[] | select(.served == true) | .name ] | join(",")')"
  [[ "$served" == *"v1alpha2"* ]] || {
    echo "agents.kagent.dev served versions: '$served' (expected v1alpha2 among them)"
    return 1
  }

  has_status="$(printf '%s' "$output" | jq -r '[ .spec.versions[] | select(.name == "v1alpha2") | .subresources.status != null ] | any')"
  [ "$has_status" = "true" ] || {
    echo "agents.kagent.dev v1alpha2 has no status subresource"
    echo "no controller can report reconciliation state through this CRD"
    return 1
  }
}

@test "kagent: kagent namespace exists with governance label" {
  run kubectl get namespace "${NS}" -o jsonpath='{.metadata.labels.controlplane\.io/governance}'
  [ "$status" -eq 0 ]
  [ "$output" = "infrastructure" ]
}

@test "kagent: controller deployment is scheduled and memory-capped" {
  # Was titled "is running" while asserting only a field of the *desired* spec.
  # A Deployment object with a memory limit and zero ready replicas satisfied
  # the old assertion completely. Assert observed status too, and read the limit
  # off the running pod rather than the template, so a rollout that never landed
  # cannot pass on the strength of the manifest it was supposed to apply.
  name="$(require_deploy controller 'controller')"

  ready="$(kubectl get deployment "$name" -n "${NS}" -o jsonpath='{.status.readyReplicas}')"
  [ "${ready:-0}" -ge 1 ]

  limit="$(kubectl get pods -n "${NS}" \
    -l app.kubernetes.io/component=controller \
    -o jsonpath='{.items[0].spec.containers[0].resources.limits.memory}' 2>/dev/null || true)"
  [ -n "$limit" ] || {
    echo "controller pod declares no memory limit — it can consume the node"
    return 1
  }

  # Normalise Mi/Gi to MiB and require a real cap. The placeholder pinned 512Mi;
  # the chart may choose another figure, and the property worth holding is that
  # a cap exists and is not absurd, not that it equals one specific string.
  case "$limit" in
    *Gi) mib=$(( ${limit%Gi} * 1024 )) ;;
    *Mi) mib=${limit%Mi} ;;
    *) mib=0 ;;
  esac
  [ "${mib:-0}" -ge 1 ] && [ "${mib:-0}" -le 4096 ] || {
    echo "controller memory limit '${limit}' is absent or above the 4Gi ceiling"
    return 1
  }
}

@test "kagent: state store is running" {
  assert_ready_with_endpoint "state store" 'postgres'
}

@test "kagent: tool server is ready and its Service has a ready endpoint" {
  # readyReplicas alone proves a pod passed its own probe. The placeholder's
  # probe was an HTTP 200 from a hardcoded handler, so this can never mean "the
  # tool server works" — see test/kagent-anti-stub.bats for that. What it can
  # mean, and now does, is that the Service actually routes somewhere.
  assert_ready_with_endpoint "tool server" 'tool'
}

@test "kagent: UI is ready and its Service has a ready endpoint" {
  assert_ready_with_endpoint "UI" 'ui$'
}

@test "kagent: postgres network policy selects a real pod and restricts ingress to the controller" {
  run kubectl get networkpolicy kagent-postgres-isolation -n "${NS}" -o json
  [ "$status" -eq 0 ]
  netpol="$output"

  # The ingress source must be the controller. Match on the component label,
  # which both the placeholder manifests and the chart set, rather than on
  # app.kubernetes.io/name — the chart gives every component name=kagent, so a
  # name-only assertion would be satisfied by any component in the release.
  from="$(printf '%s' "$netpol" | jq -r '(.spec.ingress[0].from[0].podSelector.matchLabels // {}) | to_entries | map("\(.key)=\(.value)") | sort | join(",")')"
  [[ "$from" == *"app.kubernetes.io/component=controller"* ]] || [[ "$from" == *"app.kubernetes.io/name=kagent"* ]] || {
    echo "ingress[0].from[0] selects '${from}'"
    echo "expected a selector naming the controller"
    return 1
  }

  # A NetworkPolicy whose podSelector matches nothing restricts nothing, and
  # reads exactly the same in `kubectl get` as one doing real work. Resolve the
  # selector against live pods so an empty selection fails here.
  sel="$(printf '%s' "$netpol" | jq -r '
    (.spec.podSelector.matchLabels // {}) | to_entries | map("\(.key)=\(.value)") | join(",")')"
  [ -n "$sel" ] || {
    echo "kagent-postgres-isolation has an empty podSelector — it applies to every pod or none"
    return 1
  }
  matched="$(kubectl get pods -n "${NS}" -l "$sel" --no-headers 2>/dev/null | grep -c . || true)"
  [ "${matched:-0}" -ge 1 ] || {
    echo "podSelector '$sel' matches 0 pods in ${NS} — this policy protects nothing"
    kubectl get pods -n "${NS}" --show-labels
    return 1
  }
}
