#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  real_kubectl="$(command -v kubectl)"
  bin="$BATS_TEST_TMPDIR/bin"
  log="$BATS_TEST_TMPDIR/commands.log"
  mkdir -p "$bin"
  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$COMMAND_LOG"
if [[ "$*" == *'get daemonset -o json'* ]]; then
  if [[ "${AGENT_TRUST_FAKE_CNI:-none}" == kindnet ]]; then
    printf '%s\n' '{"items":[{"metadata":{"name":"kindnet"}}]}'
  else
    printf '%s\n' '{"items":[]}'
  fi
fi
if [[ "$*" == *'api-resources --api-group=networking.k8s.io -o name'* ]]; then printf 'networkpolicies\n'; fi
if [[ "$*" == *'get pods -l app.kubernetes.io/name=agent-trust-triage'* ]]; then printf 'true\n'; fi
if [[ "$*" == *'get deployment openbao -o json'* ]]; then printf '%s\n' '{"spec":{"template":{"spec":{"containers":[{"name":"openbao","env":[{"name":"BAO_DEV_ROOT_TOKEN_ID","value":"fixture-admin-token"}]}]}}}}'; fi
# Carries bound_subject/bound_audiences/token_policies as well as the lifetime.
# The old fixture returned lifetime only, so verify's identity-binding assertions
# had nothing to bind against — dropping bound_subject from role creation left
# every gate green while any SVID with the right audience could log in as the
# planner.
if [[ "$*" == *'bao read -format=json auth/jwt/role/agent-trust-'* ]]; then
  at_args="$*"; at_role="${at_args##*auth/jwt/role/agent-trust-}"; at_role="${at_role%% *}"
  at_sub="spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/${at_role}"
  [[ "${AGENT_TRUST_FAKE_UNBOUND_ROLE:-0}" == 1 && "$at_role" == planner ]] && at_sub=""
  printf '{"data":{"token_type":"batch","token_ttl":300,"token_max_ttl":300,"token_period":0,"bound_subject":"%s","bound_audiences":["openbao-supercredential"],"token_policies":["agent-trust-acme-payments"]}}\n' "$at_sub"
fi
# Matches the planner selector without pinning its full text. The script excludes
# probe pods via `,app.kubernetes.io/component!=probe`, and a shim pinned to the
# bare selector silently returned nothing the moment that exclusion was added --
# turning eleven tests red for a reason unrelated to what they assert.
if [[ "$*" == *'get pods -l app.kubernetes.io/name=agent-trust-planner'*'-o json'* ]]; then
  printf '%s\n' '{"items":[{"metadata":{"name":"planner-0"},"status":{"containerStatuses":[{"ready":true}]}}]}'
fi
if [[ "$*" == *'exec planner-0 -- /usr/local/bin/spire-agent api fetch jwt'* ]]; then
  printf '%s\n' '[{"svids":[{"svid":"fixture-jwt"}]}]'
fi
if [[ "$*" == *'sh -ec'* && "$*" == *'bao write -format=json auth/jwt/login role=agent-trust-planner'* ]]; then
  if [[ "${AGENT_TRUST_FAKE_RENEWABLE_TOKEN:-0}" == 1 ]]; then
    printf '%s\n' '{"auth":{"renewable":true,"lease_duration":300,"client_token":"fixture-service"}}'
  else
    printf '%s\n' '{"auth":{"renewable":false,"lease_duration":300,"client_token":"fixture-batch"}}'
  fi
fi
if [[ "$*" == *'sh -ec'* && "$*" == *'bao token renew'* ]]; then
  if [[ "${AGENT_TRUST_FAKE_RENEW_TRANSPORT_FAILURE:-0}" == 1 ]]; then printf 'connection refused\n' >&2; exit 1; fi
  if [[ "${AGENT_TRUST_FAKE_RENEW_SUCCESS:-0}" == 1 ]]; then printf 'renewed\n'; exit 0; fi
  printf 'batch tokens cannot be renewed\n' >&2
  exit 2
fi
if [[ "$*" == *'get pod -l app.kubernetes.io/name=spire-server -o jsonpath='* ]]; then printf 'spire-server-0'; fi
# Must echo the SELECTORS, not just an Entry ID. verify asserts k8s:ns/k8s:sa
# because those are the workload-attestation property; a fixture that returns a
# bare "Entry ID" would let the selector assertions pass against a response that
# never carried a selector at all — the exact gate-that-cannot-fail this shim
# exists to exercise.
if [[ "$*" == *'spire-server entry show -spiffeID'* ]]; then
  at_args="$*"; at_id="${at_args##*-spiffeID }"; at_id="${at_id%% *}"
  case "$at_id" in
    */payments/agent/planner)      at_ns=agent-trust-acme-payments;              at_sa=agent-trust-planner ;;
    */payments/agent/triage)       at_ns=agent-trust-acme-payments;              at_sa=agent-trust-triage ;;
    */risk/agent/risk-reader)      at_ns=agent-trust-acme-risk;                  at_sa=agent-trust-risk-reader ;;
    */investigations/agent/investigator) at_ns=agent-trust-northstar-investigations; at_sa=agent-trust-investigator ;;
    *) at_ns=unknown; at_sa=unknown ;;
  esac
  [[ "${AGENT_TRUST_FAKE_MISSING_SA_SELECTOR:-0}" == 1 && "$at_sa" == agent-trust-planner ]] && at_sa=""
  printf 'Entry ID : fixture-entry\n'
  printf 'SPIFFE ID : %s\n' "$at_id"
  printf 'Selector : k8s:ns:%s\n' "$at_ns"
  [[ -n "$at_sa" ]] && printf 'Selector : k8s:sa:%s\n' "$at_sa"
fi
if [[ "$*" == *'exec deployment/'* ]]; then
  if [[ "${AGENT_TRUST_FAKE_UNEXPECTED_ALLOW:-0}" == 1 && "$*" == *'deployment/agent-trust-risk-reader'* ]]; then exit 0; fi
  # Breakage that exits 1 exactly like a dropped packet does. Scoped to the nc
  # probes so the call-a2a exec is untouched. The stderr strings are copied from
  # real failures: busybox nc emits "bad address", and kubectl emits the exec and
  # not-found messages.
  if [[ "$*" == *' nc -z '* && "${AGENT_TRUST_FAKE_DNS_FAILURE:-0}" == 1 && "$*" == *'deployment/agent-trust-risk-reader'* ]]; then
    printf "nc: bad address 'agent-trust-triage.agent-trust-acme-payments.svc'\n" >&2; exit 1
  fi
  if [[ "$*" == *' nc -z '* && "${AGENT_TRUST_FAKE_NC_MISSING:-0}" == 1 && "$*" == *'deployment/agent-trust-risk-reader'* ]]; then
    printf 'OCI runtime exec failed: exec failed: unable to start container process: exec: "nc": executable file not found in $PATH\n' >&2; exit 126
  fi
  if [[ "$*" == *' nc -z '* && "${AGENT_TRUST_FAKE_PROBE_POD_ABSENT:-0}" == 1 && "$*" == *'deployment/agent-trust-risk-reader'* ]]; then
    printf 'error: unable to upgrade connection: container not found ("risk-reader")\n' >&2; exit 1
  fi
  if [[ "$*" == *'deployment/agent-trust-risk-reader'* || "$*" == *'deployment/agent-trust-investigator'* || "$*" == *' 1.1.1.1 443'* ]]; then exit 1; fi
fi
if [[ "$*" == *'get resourceset -o json'* ]]; then
  printf '%s\n' '{"items":[{"metadata":{"name":"signalloom-infra"},"spec":{"inputs":[{"tenant":"inf-bao","tag":"latest"}]}},{"metadata":{"name":"signalloom-apps"},"spec":{"inputs":[{"tenant":"fe-signalloom","tag":"latest"}]}},{"metadata":{"name":"olly"},"spec":{"inputs":[]}}]}'
fi
if [[ "${AGENT_TRUST_FAKE_ABSENT:-0}" == 1 && "$*" == *'get namespace agent-trust-'* ]]; then exit 1; fi
if [[ "${AGENT_TRUST_FAKE_DOWN_FAILURE:-0}" == 1 && "$*" == *'metadata.annotations.agent-trust'* ]]; then printf 'true'; fi
if [[ "$*" == *'get resourceset/agent-trust -o jsonpath='* && "$*" != *'metadata.annotations.agent-trust'* ]]; then printf '[]'; fi
if [[ "${AGENT_TRUST_FAKE_DOWN_FAILURE:-0}" == 1 && "$*" == *'delete namespace agent-trust-platform'* ]]; then exit 1; fi
SCRIPT
cat >"$bin/flux" <<'SCRIPT'
#!/usr/bin/env bash
printf 'flux %s\n' "$*" >>"$COMMAND_LOG"
if [[ "${AGENT_TRUST_FAKE_RECONCILE_FAILURE:-0}" == 1 && "$*" == *'reconcile kustomization agent-trust'* ]]; then exit 1; fi
SCRIPT
  chmod +x "$bin/kubectl" "$bin/flux"
}

line_number() {
  local first line=""
  first="$(grep -n -F "$1" "$log" | cut -d: -f1 | { IFS= read -r line || true; printf '%s' "$line"; })"
  printf '%s\n' "$first"
}

@test "lifecycle preflights Bao before patching the opt-in ResourceSet" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" "$root/scripts/agent-trust-local.sh" up
  [ "$status" -eq 0 ]
  [[ "$output" == *"Agent Trust local reconciliation converged"* ]]
  grep -Fq 'reconcile kustomization flux-system -n flux-system --with-source' "$log"
  grep -Fq 'suspend kustomization tenants -n flux-system' "$log"
  grep -Fq 'get resourceset agent-trust' "$log"
  grep -Fq 'get resourceset -o json' "$log"
  grep -Fq 'patch resourceset/signalloom-infra --type merge -p {"spec":{"inputs":[{"tenant":"inf-bao","tag":"latest"}]}}' "$log"
  grep -Fq 'patch resourceset/signalloom-apps --type merge -p {"spec":{"inputs":[{"tenant":"fe-signalloom","tag":"latest"}]}}' "$log"
  ! grep -Fq 'patch resourceset/olly --type merge' "$log"
  grep -Fq 'wait resourceset/signalloom-infra --for=condition=ready' "$log"
  grep -Fq 'wait kustomization/infra-configs --for=condition=ready' "$log"
  grep -Fq 'patch resourceset/agent-trust --type merge' "$log"
  grep -Fq 'reconcile kustomization agent-trust -n agent-trust-platform --with-source' "$log"
  grep -Fq 'bao write "auth/jwt/role/agent-trust-${agent}"' "$log"
  grep -Fq 'bao read -format=json auth/jwt/role/agent-trust-planner' "$log"
  grep -Fq 'spire-server entry show -spiffeID spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner' "$log"
  grep -Fq 'rollout status deploy/agent-trust-triage' "$log"
  grep -Fq 'get service agent-trust-triage' "$log"
  restore=$(line_number 'patch resourceset/signalloom-infra --type merge')
  suspend=$(line_number 'suspend kustomization tenants -n flux-system')
  bao_preflight=$(line_number 'wait resourceset/signalloom-infra --for=condition=ready')
  [ "$suspend" -lt "$restore" ]
  [ "$restore" -lt "$bao_preflight" ]
}

@test "Agent Trust Flux bootstrap grants roles and rolebindings before reconciliation" {
  fleet="$root/d2-osramp-fleet/tenants/base/agent-trust.yaml"
  run yq -o=json 'select(.kind == "ResourceSet") | .spec.resources[] | select(.kind == "ClusterRole" and .metadata.name == "agent-trust-flux-workloads")' "$fleet"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"roles"'* ]]
  [[ "$output" == *'"rolebindings"'* ]]
  [[ "$output" == *'"pods"'* ]]
  [[ "$output" == *'"patch"'* ]]
}

@test "repeat activation changes nonce without changing logical Agent Trust inputs" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_ACTIVATION_NONCE=first \
    "$root/scripts/agent-trust-local.sh" up
  [ "$status" -eq 0 ]
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_ACTIVATION_NONCE=second \
    "$root/scripts/agent-trust-local.sh" up
  [ "$status" -eq 0 ]
  mapfile -t patches < <(grep 'patch resourceset/agent-trust --type merge' "$log")
  [ "${#patches[@]}" -eq 2 ]
  [[ "${patches[0]}" == *'"activationNonce":"first"'* ]]
  [[ "${patches[1]}" == *'"activationNonce":"second"'* ]]
  [[ "${patches[0]}" == *'"tenant":"agent-trust-platform"'* ]]
  [[ "${patches[1]}" == *'"tenant":"agent-trust-platform"'* ]]
}

@test "failed reconciliation rolls activation back to inactive inputs" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_RECONCILE_FAILURE=1 \
    "$root/scripts/agent-trust-local.sh" up
  [ "$status" -ne 0 ]
  [[ "$output" == *"restoring ResourceSet inputs to []"* ]]
  grep -Fq 'patch resourceset/agent-trust --type merge -p {"spec":{"inputs":[]}}' "$log"
  grep -Fq 'flux resume kustomization flux-system -n flux-system' "$log"
  grep -Fq 'flux resume kustomization tenants -n flux-system' "$log"
}

@test "network test fails closed when no CNI daemonset is present" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  ! grep -Fq 'exec deployment/' "$log"
}

@test "kindnet is admitted to dataplane probes without name-based enforcement inference" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"NetworkPolicy evidence passed"* ]]
  [[ "$output" == *"five-minute non-renewable batch token"* ]]
  grep -Fq 'api-resources --api-group=networking.k8s.io -o name' "$log"
  grep -Fq 'sh -ec' "$log"
  grep -Fq 'bao token renew' "$log"
  grep -Fq 'exec deployment/agent-trust-planner -- nc -z -w 5 agent-trust-triage 8080' "$log"
  grep -Fq 'exec deployment/agent-trust-planner -- /usr/local/bin/signalloom-spire-proof call-a2a -audience openbao-supercredential' "$log"
  grep -Fq 'exec deployment/agent-trust-risk-reader -- nc -z -w 5 agent-trust-triage.agent-trust-acme-payments.svc 8080' "$log"
}

@test "renewable OpenBao token fails authenticated network evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet AGENT_TRUST_FAKE_RENEWABLE_TOKEN=1 \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"renewable or exceeds five minutes"* ]]
  ! grep -Fq 'signalloom-spire-proof call-a2a' "$log"
}

@test "renewal transport failure cannot prove a batch-token denial" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet AGENT_TRUST_FAKE_RENEW_TRANSPORT_FAILURE=1 \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"renewal denial could not be proven"* ]]
  ! grep -Fq 'signalloom-spire-proof call-a2a' "$log"
}

@test "unexpectedly renewable batch token fails authenticated evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet AGENT_TRUST_FAKE_RENEW_SUCCESS=1 \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpectedly renewed"* ]]
  ! grep -Fq 'signalloom-spire-proof call-a2a' "$log"
}

# A denial is only evidence if the probe could have succeeded. `nc` exits 1 for a
# dropped packet, an unresolvable name, a missing binary and a dead container
# alike — so without these three, every deny assertion in the suite passes on any
# breakage and the run still prints "enforced NetworkPolicy evidence passed".
# Verified against busybox:1.36, the image the scaffold pods actually run:
# `nc -z -w 2 240.0.0.1 9999` and `nc -z -w 2 nope.invalid 9999` both exit 1.

@test "a denial that is really a DNS failure is UNVERIFIED, not evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_DNS_FAILURE=1 "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  [[ "$output" == *"DNS failed"* ]]
  [[ "$output" != *"NetworkPolicy evidence passed"* ]]
}

@test "a denial produced by a missing nc binary is UNVERIFIED, not evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_NC_MISSING=1 "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  [[ "$output" == *"probe itself is unusable"* ]]
  [[ "$output" != *"NetworkPolicy evidence passed"* ]]
}

@test "a denial from a pod that is not running is UNVERIFIED, not evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_PROBE_POD_ABSENT=1 "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  [[ "$output" == *"is not running"* ]]
  [[ "$output" != *"NetworkPolicy evidence passed"* ]]
}

# The probe CronJobs carry the planner's app label so the NetworkPolicies that
# select on it actually apply to them -- without it they could never reach
# OpenBao or triage and failed on every run. But that label also makes them match
# `kubectl get pods -l app.kubernetes.io/name=agent-trust-planner`, and
# verify_nonrenewable_planner_token errors unless EXACTLY ONE ready pod matches.
# A probe running concurrently would therefore break the demo intermittently with
# "expected one ready planner pod". The component exclusion is what prevents that,
# and nothing else in the suite would notice if it were dropped.
# The two properties this slice exists to demonstrate — SPIFFE workload
# attestation and OpenBao subject binding — were the two the verification path
# never checked. `verify` asserted a SPIRE entry EXISTS (not its selectors) and
# that an OpenBao role is short-lived (not whose it is). Either could be removed
# entirely with verify, the network probes, bats and test_contracts.py all green:
# drop `-selector k8s:sa:...` and any pod in agent-trust-acme-payments can fetch
# the planner's SVID; drop `bound_subject=` and any SVID with the right audience
# logs in as the planner and reads the payments KV path.

@test "a SPIRE entry missing its ServiceAccount selector fails verification" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_MISSING_SA_SELECTOR=1 "$root/scripts/agent-trust-local.sh" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing selector k8s:sa:agent-trust-planner"* ]]
  [[ "$output" == *"could assume this identity"* ]]
}

@test "an OpenBao role not bound to its SPIFFE subject fails verification" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet \
    AGENT_TRUST_FAKE_UNBOUND_ROLE=1 "$root/scripts/agent-trust-local.sh" verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"not bound to its SPIFFE subject"* ]]
}

@test "the planner pod lookup excludes probe pods it would otherwise collide with" {
  grep -Fq 'app.kubernetes.io/name=agent-trust-planner,app.kubernetes.io/component!=probe' \
    "$root/scripts/agent-trust-local.sh"
}

@test "every planner-labelled probe also carries the component label that exempts it" {
  local probes="$root/d2-agent-trust/manifests/topology-probes.yaml"
  run python3 -c '
import sys, yaml
bad = []
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "CronJob":
        continue
    labels = d["spec"]["jobTemplate"]["spec"]["template"]["metadata"].get("labels", {})
    if labels.get("app.kubernetes.io/name") == "agent-trust-planner" \
       and labels.get("app.kubernetes.io/component") != "probe":
        bad.append(d["metadata"]["name"])
print(",".join(bad))
' "$probes"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unexpectedly allowed denied dataplane path fails network evidence" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_CNI=kindnet AGENT_TRUST_FAKE_UNEXPECTED_ALLOW=1 \
    "$root/scripts/agent-trust-local.sh" network-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpectedly allowed"* ]]
}

@test "lifecycle contains no fixed readiness sleeps and teardown is owned-only" {
  script="$root/scripts/agent-trust-local.sh"
  ! grep -E '(^|[;[:space:]])sleep[[:space:]]+[0-9]' "$script"
  grep -Fq 'patch "resourceset/${resource_set}" --type merge -p '\''{"spec":{"inputs":[]}}'\''' "$script"
  grep -Fq 'kubectl delete namespace "$namespace"' "$script"
  ! grep -Fq 'delete namespace "$bao_namespace"' "$script"
}

@test "down deactivates the ResourceSet then removes only owned namespaces" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_ABSENT=1 \
    "$root/scripts/agent-trust-local.sh" down
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-existing inf-bao deployment remains intact"* ]]
  grep -Fq 'patch resourceset/agent-trust --type merge -p {"spec":{"inputs":[]}}' "$log"
  grep -Fq 'get resourceset/agent-trust -o jsonpath={.spec.inputs}' "$log"
  grep -Fq 'delete namespace agent-trust-platform --ignore-not-found --wait=true' "$log"
  grep -Fq 'delete namespace agent-trust-northstar-investigations --ignore-not-found --wait=true' "$log"
  ! grep -Fq 'delete namespace inf-bao' "$log"
  grep -Fq 'bao delete auth/jwt/role/agent-trust-planner' "$log"
}

@test "failed teardown still resumes root Fleet reconciliation" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" AGENT_TRUST_FAKE_DOWN_FAILURE=1 \
    "$root/scripts/agent-trust-local.sh" down
  [ "$status" -ne 0 ]
  grep -Fq 'flux resume kustomization flux-system -n flux-system' "$log"
  grep -Fq 'flux resume kustomization tenants -n flux-system' "$log"
}

@test "ResourceSet uses limited Agent Trust RBAC and signed OCI wiring" {
  resource="$root/d2-osramp-fleet/tenants/base/agent-trust.yaml"
  grep -Fq 'inputs: []' "$resource"
  grep -Fq 'name: signalloom-infra' "$resource"
  grep -Fq 'namespace: inf-bao' "$resource"
  grep -Fq 'name: agent-trust-flux' "$resource"
  grep -Fq 'resources: [namespaces]' "$resource"
  [ "$(grep -c 'kind: Namespace' "$resource")" -eq 6 ]
  [ "$(grep -c 'kind: RoleBinding' "$resource")" -eq 12 ]
  grep -Fq 'verbs: [get, list, watch, create]' "$resource"
  grep -Fq 'verbs: [get, update, patch, delete]' "$resource"
  grep -Fq 'resourceNames:' "$resource"
  grep -Fq 'resources: [deployments, replicasets]' "$resource"
  ! grep -Fq 'cluster-admin' "$resource"
  grep -Fq 'provider: cosign' "$resource"
  grep -Fq 'artifactSubjectWorkflow' "$resource"
  grep -Fq 'push_and_sign "signalloom/agent-trust" "d2-agent-trust/manifests"' "$root/scripts/push-local.sh"
  grep -Fq 'repository: signalloom/agent-trust' "$root/.github/workflows/push-artifacts.yaml"
  grep -Fq 'name: allow-agent-trust-openbao' "$resource"
  grep -Fq 'agent-trust.signalloom.io/project: payments' "$resource"
  grep -Fq 'app.kubernetes.io/name: agent-trust-planner' "$resource"
  grep -Fq 'app.kubernetes.io/name: agent-trust-triage' "$resource"
  grep -Fq 'port: 8200' "$resource"
  grep -Fq '"serve-a2a"' "$root/d2-agent-trust/manifests/boundaries.yaml"
  grep -Fq 'readinessProbe: {httpGet: {path: /readyz, port: a2a}' "$root/d2-agent-trust/manifests/boundaries.yaml"
  ! grep -R -Fq 'activationNonce' "$root/d2-agent-trust/manifests"
}

@test "local fleet renders inactive Agent Trust with local signature verification" {
  rendered="$BATS_TEST_TMPDIR/tenants-local.yaml"
  run "$real_kubectl" kustomize --load-restrictor LoadRestrictionsNone "$root/d2-osramp-fleet/tenants/local"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$rendered"
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "agent-trust") | (.spec.inputs | length) == 0' "$rendered"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  # Selected by kind, not by position. This asserted .spec.resources[16] until
  # the topology collector's ClusterRole and its fake-proxy ClusterRoleBinding
  # were added above the OCIRepository and shifted it to 18 -- index 16 is now
  # ClusterRole/agent-trust-topology-namespaces, so the test failed while the
  # manifest was correct. The cosign patch in tenants/local/kustomization.yaml
  # is positional and has to be realigned by hand (cosign-patch-index.bats
  # guards that), but nothing forces this assertion to move with it, and a
  # stale index here fails loudly at best and silently checks the wrong
  # resource at worst.
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "agent-trust") | .spec.resources[] | select(.kind == "OCIRepository") | .spec.verify.secretRef.name == "cosign-pub"' "$rendered"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run yq -e 'select(.kind == "ResourceSet" and .metadata.name == "agent-trust") | .spec.dependsOn[] | select(.name == "signalloom-infra" or (.name == "infra-configs" and .namespace == "inf-bao")) | .readyExpr | contains("conditions")' "$rendered"
  [ "$status" -eq 0 ]
  [[ "$output" == *"true"* ]]
}

@test "Agent Trust Make target publishes bounded artifacts only" {
  run make -n demo-agent-trust-up
  [ "$status" -eq 0 ]
  [[ "$output" == *"push-local-fleet"* ]]
  [[ "$output" == *"push-local-agent-trust"* ]]
  [[ "$output" == *"signalloom-spire-helper"* ]]
  [[ "$output" != *"push-local-signalloom"* ]]
}
