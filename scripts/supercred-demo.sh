#!/usr/bin/env bash
# SuperCred demo lifecycle: identity chain → compliance scan → agent stun.
#
# Five numbered steps, each with a preflight check:
#   supercred-demo.sh 1   # Deploy services, agent, OpenBao secrets, SPIRE entry
#   supercred-demo.sh 2   # Run the agent's credential chain
#   supercred-demo.sh 3   # Compliance scan — discovers missing securityContext
#   supercred-demo.sh 4   # Stun: revoke credentials, verify denial
#   supercred-demo.sh 5   # Teardown + verify clean
#   supercred-demo.sh all # Run 1→5 sequentially
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh"

NAMESPACE_INFRA="inf-signalloom"
NAMESPACE_BAO="inf-bao"
NAMESPACE_AGENTS="fe-signalloom-agents"
SPIFFE_ID="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent"
PARENT_ID="spiffe://signalloom.demo/agent/kind"

# agents-cardvault.yaml declares `namespace: fe-signalloom-agents`, but the Flux
# Kustomization's targetNamespace can override that and land the pod in
# fe-signalloom instead. NAMESPACE_AGENTS stays the default (and the namespace
# this script creates and deletes Jobs in); AGENT_POD_NAMESPACE is resolved at
# runtime so label/annotate/get calls follow the pod wherever Flux placed it.
IFS=' ' read -r -a AGENT_NAMESPACE_CANDIDATES \
  <<< "${AGENT_NAMESPACE_CANDIDATES:-fe-signalloom-agents fe-signalloom}"
AGENT_POD_NAMESPACE="$NAMESPACE_AGENTS"

# Narration carries the wall-clock instant it was PRINTED.
#
# Only these three functions are stamped, and that is the design, not an
# omission. Everything else this script emits — OpenBao's replies, the agent
# pod's log, the compliance results — is output it is QUOTING from somewhere
# else, and it quotes them after the fact: the agent's denial line is read back
# up to SUPERCRED_STUN_EVIDENCE_TIMEOUT seconds after the pod wrote it. A stamp
# on those lines would be the time this script echoed them, presented as the
# time they happened. In a demo whose subject is evidence, a clock that lies is
# worse than no clock. So the timestamp goes only where it is true: on lines
# this script authored at the moment it printed them.
#
# UTC, with an explicit Z. This script runs from a terminal in Europe/London
# and from inside the demo-runner pod, and the same instant would otherwise
# print two ways with nothing on the line to say which. It also matches the UTC
# that step 4 already writes into the signalloom.ai/stunned-at annotation, so
# the log line and the artefact it produced agree.
#
# The `TZ=UTC` prefix is LOAD-BEARING — do not drop it on the reasoning that
# the runner's child environment has no TZ anyway. glibc falls back to
# /etc/localtime when TZ is unset, so on a developer's machine
# `env -i bash -c 'printf "%(%H:%M:%S)T" -1'` prints BST, not UTC. Setting it
# here at the point of use also keeps this off demo_runner.py's _ENV_ALLOWLIST:
# a TZ inherited from the parent would be silently starved on exactly the
# dashboard-invoked path that matters, and print local time in a terminal.
#
# Seconds, not milliseconds. These lines bracket kubectl calls and rollout
# waits that are seconds to minutes apart, and the things worth correlating
# them against — Kubernetes event timestamps, the stun annotation — are
# themselves second-resolution. Milliseconds would advertise a precision
# nothing else in the demo can be aligned to.
#
# printf's %(fmt)T is a bash builtin (4.2+), so a stamp costs no `date` fork
# and no new dependency: moreutils `ts` is not in the runner image
# (d2-signalloom/apps/supercred-demo-runner/Dockerfile installs bash, curl,
# wget and kubectl, nothing more).
log() { TZ=UTC printf '[%(%H:%M:%SZ)T] \033[1;36m[supercred]\033[0m %s\n' -1 "$*"; }
ok()  { TZ=UTC printf '[%(%H:%M:%SZ)T] \033[1;32m[supercred] ✓\033[0m %s\n' -1 "$*"; }
warn() { TZ=UTC printf '[%(%H:%M:%SZ)T] \033[1;33m[supercred] WARNING:\033[0m %s\n' -1 "$*" >&2; }
fail() { TZ=UTC printf '[%(%H:%M:%SZ)T] \033[1;31m[supercred] FAILED:\033[0m %s\n' -1 "$*" >&2; exit 1; }

# Sets AGENT_POD_NAMESPACE to the namespace that actually holds agent-cardvault.
# Falls back to NAMESPACE_AGENTS and returns non-zero when the pod is nowhere.
resolve_agent_pod_namespace() {
  local ns
  for ns in "${AGENT_NAMESPACE_CANDIDATES[@]}"; do
    if kubectl -n "$ns" get pod agent-cardvault >/dev/null 2>&1; then
      AGENT_POD_NAMESPACE="$ns"
      if [ "$ns" != "$NAMESPACE_AGENTS" ]; then
        log "agent-cardvault resolved to namespace $ns (Flux relocated it from $NAMESPACE_AGENTS)"
      fi
      return 0
    fi
  done
  AGENT_POD_NAMESPACE="$NAMESPACE_AGENTS"
  return 1
}

spire_pod() {
  kubectl -n "$NAMESPACE_BAO" get pod -l app.kubernetes.io/name=spire-server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ─── Preflight checks ───────────────────────────────────────────────────────

preflight_cluster() {
  log "preflight: checking cluster health"
  kubectl cluster-info >/dev/null 2>&1 || fail "cluster not reachable"
  kubectl get ns "$NAMESPACE_BAO" >/dev/null 2>&1 || fail "namespace $NAMESPACE_BAO not found — run make demo-signalloom-up first"
  kubectl get ns "$NAMESPACE_INFRA" >/dev/null 2>&1 || fail "namespace $NAMESPACE_INFRA not found — run make demo-signalloom-up first"
  # wait_rollout, not wait_k8s_ready: the latter defaults to --for=condition=ready,
  # and a Deployment has no Ready condition — only Available, Progressing and
  # ReplicaFailure. `kubectl wait --for=condition=ready deployment/openbao` therefore
  # times out even when the Deployment is perfectly healthy, so this preflight failed
  # closed against a live, 1/1, Available=True OpenBao and told the operator to run
  # `make demo-signalloom-up` on a cluster where it had already been run.
  #
  # wait_rollout uses `kubectl rollout status`, which is the correct readiness check
  # for a Deployment and already existed in the shared helper.
  wait_rollout openbao -n "$NAMESPACE_BAO" 30 \
    || fail "OpenBao not running — run make demo-signalloom-up first"
  wait_rollout spire-server -n "$NAMESPACE_BAO" 30 \
    || fail "SPIRE server not running — run make demo-signalloom-up first"
  wait_pods_ready "app.kubernetes.io/name=spire-agent" -n "$NAMESPACE_BAO" 60 \
    || fail "SPIRE agent not ready — the agent needs a valid join token. Check: kubectl -n inf-bao logs daemonset/spire-agent"
  ok "cluster healthy, OpenBao + SPIRE + agent running"
}

preflight_images() {
  # kind-loaded :local images do NOT survive a `kind delete/create`, but the
  # namespaces/Jobs referencing them can be re-applied — leaving a manifest
  # pointing at an image that is no longer on the node. containerd then falls
  # back to the pull-through mirror and fails with "unexpected media type
  # text/html" (ImagePullBackOff). Verify the images are present before any step
  # applies a workload that needs them.
  #
  # This check used to grep `ctr -n k8s.io images ls`, which passes for an image
  # whose manifest is in the content store but whose layers never transferred —
  # precisely the state that produces the text/html unpack failure. Verification
  # now lives in supercred-images.sh and uses `crictl images` (the CRI's view of
  # what is actually runnable) so a half-loaded image is reported as missing.
  log "preflight: verifying supercred images are loaded on the node"
  # Three outcomes, and this caller's policy on each is stated rather than
  # implied. Exit 3 is COULD-NOT-VERIFY — the node's listing is truncated
  # (node.status.images is capped at 50 and size-sorted) and simply cannot
  # answer. Blocking on that halted the entire demo on 2026-08-03 against a node
  # that held every image. Continuing is safe HERE specifically because the pods
  # use imagePullPolicy: IfNotPresent. Kubelet attempts a registry pull for an absent image,
  # so the workload's pull error is the concrete follow-up signal.
  #
  # That reasoning does not transfer to the build path, which is why
  # supercred-images.sh `load` treats 3 as a stop rather than a shrug: there,
  # "we cannot tell whether this is the binary we just built" is the whole
  # question and there is no later check to fall back on.
  local rc=0
  "${SCRIPT_DIR}/supercred-images.sh" verify || rc=$?
  case "$rc" in
    0) ok "supercred images present on the node" ;;
    3) warn "supercred image presence COULD NOT BE VERIFIED (truncated node listing) — continuing; an absent image triggers a registry pull under IfNotPresent" ;;
    *) fail "supercred images missing or unusable on the kind node
       (kind-loaded :local images do not survive a cluster recreate)
       rebuild + reload them:  make demo-signalloom-supercred-images" ;;
  esac
}

preflight_step1_deployed() {
  log "preflight: verifying step 1 resources"
  wait_k8s_exists deployment cardvault -n "$NAMESPACE_INFRA" 10 \
    || fail "cardvault not deployed — run step 1 first"
  wait_k8s_exists deployment policy-engine -n "$NAMESPACE_INFRA" 10 \
    || fail "policy-engine not deployed — run step 1 first"
  resolve_agent_pod_namespace \
    || fail "agent-cardvault pod not found in ${AGENT_NAMESPACE_CANDIDATES[*]} — run step 1 first"
  wait_k8s_exists pod agent-cardvault -n "$AGENT_POD_NAMESPACE" 10 \
    || fail "agent-cardvault pod not found — run step 1 first"
  ok "step 1 resources present (agent pod in $AGENT_POD_NAMESPACE)"
}

preflight_step2_completed() {
  log "preflight: verifying credential chain ran"
  resolve_agent_pod_namespace || fail "agent-cardvault pod not found — run step 1 first"
  local state
  state=$(kubectl -n "$AGENT_POD_NAMESPACE" get pod agent-cardvault \
    -o jsonpath='{.metadata.labels.signalloom\.ai/state}' 2>/dev/null)
  [ "$state" = "active" ] || [ "$state" = "non-compliant" ] \
    || fail "agent state is '$state' — run step 2 first (expected active or non-compliant)"
  ok "agent state = $state (credential chain completed)"
}

# Renamed from preflight_step3_completed. The compliance scan (step 3) is a
# DEMO step, not a precondition for the stun. A superadmin must be able to
# revoke an agent's credentials whether or not the compliance scan has run —
# the whole point of the platform is that a misbehaving-but-compliant workload
# is still stunnable. What matters is that the agent EXISTS and has CREDENTIALS
# to revoke (step 2), not that the compliance scan has labelled it first.
#
# Previous behaviour hard-failed with "run step 3 first (expected
# non-compliant)", which blocked the demo and the two-window acceptance spec
# unless a compliance scan had already run — exactly backwards for a platform
# that exists to give operators the ability to act on any agent, any time.
preflight_agent_stunnable() {
  log "preflight: verifying agent is deployed and stunnable"
  resolve_agent_pod_namespace || fail "agent-cardvault pod not found — run step 1 first"
  local state
  state=$(kubectl -n "$AGENT_POD_NAMESPACE" get pod agent-cardvault \
    -o jsonpath='{.metadata.labels.signalloom\.ai/state}' 2>/dev/null)
  [ "$state" = "active" ] || [ "$state" = "non-compliant" ] \
    || fail "agent state is '$state' — run step 2 first (expected active or non-compliant)"
  if [ "$state" = "active" ]; then
    ok "agent state = active (compliant, stunnable without a compliance scan)"
  else
    ok "agent state = non-compliant (compliance scan completed, stunnable)"
  fi
}

# ─── STEP 1: Deploy ─────────────────────────────────────────────────────────

demo_1() {
  preflight_cluster
  preflight_images
  log "step 1: clean + deploy supercred services"

  # Ensure agents namespace exists (annotated to prevent Flux pruning)
  kubectl create namespace "$NAMESPACE_AGENTS" --dry-run=client -o yaml | \
    kubectl apply -f - 2>/dev/null || true
  kubectl annotate namespace "$NAMESPACE_AGENTS" \
    kustomize.toolkit.fluxcd.io/prune=disabled --overwrite 2>/dev/null || true

  # Clean previous runs (idempotent)
  kubectl delete job supercred-agent-run -n "$NAMESPACE_AGENTS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl delete job openbao-supercred-bootstrap -n "$NAMESPACE_BAO" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  resolve_agent_pod_namespace || true
  kubectl delete pod agent-cardvault -n "$AGENT_POD_NAMESPACE" --ignore-not-found --wait=true >/dev/null 2>&1 || true

  # Clean SPIRE entry from previous run
  local spire_pod
  spire_pod=$(spire_pod)
  if [ -n "$spire_pod" ]; then
    local entry_id
    entry_id=$(kubectl -n "$NAMESPACE_BAO" exec "$spire_pod" -- \
      /opt/spire/bin/spire-server entry show -spiffeID "$SPIFFE_ID" 2>/dev/null \
      | grep "Entry ID" | awk '{print $NF}') || true
    if [ -n "$entry_id" ]; then
      kubectl -n "$NAMESPACE_BAO" exec "$spire_pod" -- \
        /opt/spire/bin/spire-server entry delete -entryID "$entry_id" >/dev/null 2>&1 || true
    fi
  fi

  # Apply NetworkPolicy updates for cross-namespace access
  log "applying NetworkPolicy updates"
  kubectl apply -f d2-signalloom/infra/inf-bao/configs/base/networkpolicy.yaml -n "$NAMESPACE_BAO" 2>/dev/null || true

  # Deploy cardvault service
  log "deploying cardvault service"
  kubectl apply -k d2-signalloom/apps/cardvault/base/ -n "$NAMESPACE_INFRA"
  wait_rollout cardvault -n "$NAMESPACE_INFRA" 120 || fail "cardvault deployment failed"

  # Deploy policy engine
  log "deploying policy-engine"
  kubectl apply -k d2-signalloom/apps/policy-engine/base/ -n "$NAMESPACE_INFRA"
  wait_rollout policy-engine -n "$NAMESPACE_INFRA" 120 || fail "policy-engine deployment failed"

  # Deploy agent (inert pod + service account)
  log "deploying cardvault agent"
  kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault-sa.yaml
  kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault.yaml
  resolve_agent_pod_namespace || true
  wait_pods_ready "app.kubernetes.io/instance=cardvault" -n "$AGENT_POD_NAMESPACE" 60 \
    || fail "agent pod failed to become ready in $AGENT_POD_NAMESPACE"

  # Re-seed OpenBao secrets (handles stun revocation from previous run)
  log "seeding OpenBao supercred secrets"
  spire_pod=$(spire_pod)
  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token sh -ec '
    cat >/tmp/policy.hcl <<POLICY
path "kv/data/signalloom/cardvault-agent" { capabilities = ["read"] }
POLICY
    bao policy write signalloom-cardvault-agent /tmp/policy.hcl
    bao write auth/jwt/role/signalloom-cardvault-agent \
      role_type=jwt bound_audiences=openbao \
      bound_subject='"$SPIFFE_ID"' \
      user_claim=sub policies=signalloom-cardvault-agent
    bao kv put kv/signalloom/cardvault-agent \
      username=cardvault-svc-account password=supercred-demo-password-2026
  '

  # Register SPIRE entry
  log "registering SPIRE entry"
  kubectl -n "$NAMESPACE_BAO" exec "$spire_pod" -- \
    /opt/spire/bin/spire-server entry create \
      -spiffeID "$SPIFFE_ID" \
      -parentID "$PARENT_ID" \
      -selector "k8s:ns:fe-signalloom-agents" \
      -selector "k8s:sa:cardvault-agent" \
      -dns cardvault-agent 2>/dev/null || true

  ok "step 1 complete — services deployed, secrets seeded, SPIRE registered"
}

# ─── STEP 2: Credential Chain ───────────────────────────────────────────────

wait_agent_job_terminal() {
  # `kubectl wait --for=condition=complete` waits its whole deadline after a
  # Job has already failed.  A failed credential chain is terminal evidence,
  # not a reason to make the instructor wait five minutes for a timeout.
  _wait_retry 300 "terminal job/supercred-agent-run -n $NAMESPACE_AGENTS" \
    "conditions=\$(kubectl -n '$NAMESPACE_AGENTS' get job supercred-agent-run -o jsonpath='{range .status.conditions[*]}{.type}={.status}{\" \"}{end}' 2>/dev/null); [[ \"\$conditions\" == *'Complete=True'* || \"\$conditions\" == *'Failed=True'* ]]" \
    || return 1

  local conditions
  conditions="$(kubectl -n "$NAMESPACE_AGENTS" get job supercred-agent-run \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}{" "}{end}')"
  [[ "$conditions" == *"Complete=True"* ]]
}

demo_2() {
  preflight_step1_deployed
  preflight_images
  log "step 2: running the agent's credential chain (SPIFFE → OpenBao → cardvault)"

  kubectl delete job supercred-agent-run -n "$NAMESPACE_AGENTS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml

  log "waiting for agent job to complete..."
  wait_agent_job_terminal || {
    log "agent job output:"
    kubectl -n "$NAMESPACE_AGENTS" logs job/supercred-agent-run --tail=50 2>/dev/null || true
    fail "agent credential chain failed"
  }

  log "agent job output:"
  kubectl -n "$NAMESPACE_AGENTS" logs job/supercred-agent-run

  kubectl -n "$AGENT_POD_NAMESPACE" label pod agent-cardvault signalloom.ai/state=active --overwrite
  ok "step 2 complete — credential chain verified, agent marked active"
}

# ─── STEP 3: Compliance Scan ────────────────────────────────────────────────

demo_3() {
  preflight_step2_completed
  log "step 3: compliance scan against cardvault agent"

  local pod_spec
  pod_spec=$(kubectl -n "$AGENT_POD_NAMESPACE" get pod agent-cardvault -o json | \
    python3 -c 'import sys,json; d=json.load(sys.stdin)["spec"]; print(json.dumps({"containers":[{"name":c["name"],"securityContext":c.get("securityContext")} for c in d.get("containers",[])], "securityContext":d.get("securityContext")}))')

  kubectl -n "$NAMESPACE_INFRA" port-forward svc/policy-engine 18081:8081 >/dev/null 2>&1 &
  local pf_pid=$!
  trap 'kill $pf_pid 2>/dev/null || true' RETURN

  wait_reachable http://localhost:18081/healthz 30 || fail "policy-engine port-forward not reachable"

  local result
  result=$(curl -sS --fail -X POST http://localhost:18081/api/v1/evaluate \
    -H 'Content-Type: application/json' \
    -d "{\"agent_id\":\"cardvault\",\"namespace\":\"$AGENT_POD_NAMESPACE\",\"pod_spec\":$pod_spec,\"checks\":[\"security-context-present\",\"run-as-non-root\",\"drop-capabilities\"]}") \
    || fail "policy-engine evaluate call failed"
  kill $pf_pid 2>/dev/null || true

  python3 -c "
import json
r = json.loads('''$result''')
print(f\"\\n  Agent: {r['agent_id']}\")
print(f\"  Compliant: {r['compliant']}\")
for c in r.get('results', []):
    icon = '✅' if c['pass'] else '❌'
    print(f\"  {icon} {c['check']}: {c['reason']}\")
print()
"

  local compliant
  compliant=$(python3 -c "import json; print(json.loads('''$result''')['compliant'])")
  if [ "$compliant" = "False" ] || [ "$compliant" = "false" ]; then
    kubectl -n "$AGENT_POD_NAMESPACE" label pod agent-cardvault signalloom.ai/state=non-compliant --overwrite
    ok "step 3 complete — agent is OUT OF COMPLIANCE"
  else
    ok "step 3 complete — agent is compliant"
  fi
}

# ─── STEP 4: Stun ───────────────────────────────────────────────────────────

BAO_SECRET_PATH="kv/signalloom/cardvault-agent"
BAO_ROLE_PATH="auth/jwt/role/signalloom-cardvault-agent"

# Runs a bao command inside the OpenBao pod with stderr MERGED INTO STDOUT and
# returns bao's own exit status.
#
# The previous form was `... 2>/dev/null || true` on both revocation calls,
# which discarded the two things that decide whether the stun happened: the
# reason for a failure, and the fact of it. A sealed vault, an expired root
# token or an unreachable pod all produced silence followed by "✓ step 4
# complete — agent stunned, credentials revoked".
bao_run() {
  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token \
    "$@" 2>&1
}

indent() { sed 's/^/    /'; }

# `kubectl exec` echoes "command terminated with exit code N" on stderr for any
# non-zero command. bao_run merges stderr so no diagnostic is lost, but that
# line is kubectl's own, not OpenBao's, and printing it inside a ✓ evidence
# block reads as a fresh error at the exact moment the demo is claiming
# success. Every failure path below reports bao's exit status explicitly, so
# dropping it from the evidence blocks (and only there) costs nothing.
drop_exec_noise() { grep -v '^command terminated with exit code [0-9]\+$' || true; }

# Reads the KV secret back and decides on the PAYLOAD, never on exit status.
#
# `bao kv delete` is a soft delete and prints "Success! Data deleted (if it
# existed)" whether or not anything was there — it is OpenBao telling you it
# ran, not that a credential is gone. `bao kv get` then exits 0 on the
# soft-deleted secret, so status is no better. The only sound test is the
# response body: revoked means data.data is null AND metadata.deletion_time is
# set, or the path is absent entirely.
assert_kv_revoked() {
  local out rc verdict
  out="$(bao_run bao kv get -format=json "$BAO_SECRET_PATH")" && rc=0 || rc=$?

  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"No value found"*)
        ok "KV credential revoked — read-back proves the path is gone:"
        printf '%s\n' "$out" | drop_exec_noise | indent
        return 0
        ;;
      *)
        fail "could not read back $BAO_SECRET_PATH to prove revocation (bao exit $rc):
$(printf '%s' "$out" | indent)"
        ;;
    esac
  fi

  verdict="$(BAO_KV_JSON="$out" python3 -c '
import json, os, sys
try:
    payload = json.loads(os.environ["BAO_KV_JSON"])
except json.JSONDecodeError as exc:
    print(f"UNREADABLE {exc}")
    sys.exit(0)
data = payload.get("data") or {}
secret = data.get("data")
deleted_at = (data.get("metadata") or {}).get("deletion_time") or ""
if secret:
    print("LIVE " + ",".join(sorted(secret)))
elif deleted_at and deleted_at != "n/a":
    print("REVOKED " + deleted_at)
else:
    print("INDETERMINATE no data and no deletion_time")
')" || verdict="UNREADABLE the read-back could not be parsed"

  case "$verdict" in
    REVOKED\ *)
      ok "KV credential revoked — read-back returns no data, deleted at ${verdict#REVOKED }:"
      printf '%s\n' "$out" | indent
      ;;
    LIVE\ *)
      fail "REVOCATION DID NOT HAPPEN — $BAO_SECRET_PATH still returns secret data (keys: ${verdict#LIVE }).
       The agent can still authenticate. Do not present this as a stun."
      ;;
    *)
      fail "could not prove revocation of $BAO_SECRET_PATH — $verdict
$(printf '%s' "$out" | indent)"
      ;;
  esac
}

# The JWT role is the other half of the stun: without it the agent's SVID
# cannot be exchanged for a token at all, whatever the KV path holds.
assert_role_revoked() {
  local out rc
  out="$(bao_run bao read "$BAO_ROLE_PATH")" && rc=0 || rc=$?

  if [ "$rc" -eq 0 ]; then
    fail "REVOCATION DID NOT HAPPEN — $BAO_ROLE_PATH still resolves, so the agent can still log in:
$(printf '%s' "$out" | indent)"
  fi
  case "$out" in
    *"No value found"*)
      ok "JWT auth role revoked — read-back proves the login path is gone:"
      printf '%s\n' "$out" | drop_exec_noise | indent
      ;;
    *)
      fail "could not prove revocation of $BAO_ROLE_PATH (bao exit $rc):
$(printf '%s' "$out" | indent)"
      ;;
  esac
}

job_condition() {
  kubectl -n "$NAMESPACE_AGENTS" get job supercred-agent-run \
    -o "jsonpath={.status.conditions[?(@.type=='$1')].status}" 2>/dev/null
}

demo_4() {
  preflight_agent_stunnable
  preflight_images
  log "step 4: revoking credentials and restricting agent"

  local kv_delete_out role_delete_out rc
  kv_delete_out="$(bao_run bao kv delete "$BAO_SECRET_PATH")" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "OpenBao rejected the KV delete — nothing was revoked (exit $rc):
$(printf '%s' "$kv_delete_out" | indent)"
  printf '%s\n' "$kv_delete_out" | indent

  role_delete_out="$(bao_run bao delete "$BAO_ROLE_PATH")" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "OpenBao rejected the auth-role delete — the agent can still log in (exit $rc):
$(printf '%s' "$role_delete_out" | indent)"
  printf '%s\n' "$role_delete_out" | indent

  log "\"(if it existed)\" is OpenBao reporting that the DELETE RAN, not that a"
  log "credential was there to remove. Reading the paths back is the proof:"
  assert_kv_revoked
  assert_role_revoked

  kubectl -n "$AGENT_POD_NAMESPACE" label pod agent-cardvault signalloom.ai/state=stunned --overwrite
  kubectl -n "$AGENT_POD_NAMESPACE" annotate pod agent-cardvault \
    "signalloom.ai/stunned-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "signalloom.ai/stun-reason=compliance-failure: securityContext not set" \
    --overwrite

  log "verifying revocation end-to-end: re-running the agent's credential chain"
  kubectl delete job supercred-agent-run -n "$NAMESPACE_AGENTS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl apply -f d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml

  # Capture the agent's output WHILE ITS POD STILL EXISTS.
  #
  # The Job controller deletes the pod the moment backoffLimit is exceeded
  # (SuccessfulDelete then BackoffLimitExceeded, ~44s in on this cluster). The
  # old code waited for the Job's terminal condition FIRST and only afterwards
  # ran `kubectl logs job/supercred-agent-run --tail=5` — by then there was no
  # pod left to read, so kubectl blocked, printed "error: timed out waiting for
  # the condition" to stderr, and `2>/dev/null` swallowed that too. The demo
  # printed NOTHING at the single moment it had something to prove, and "✓ step
  # 4 complete — agent stunned, credentials revoked" rested on nothing but the
  # Job having failed to succeed — which a missing image, an unschedulable pod
  # or a deleted ServiceAccount produce just as readily as a revoked credential.
  #
  # Polling for the pod and reading its log in full is what makes the claim
  # evidenced. --tail is deliberately absent: the whole chain is four lines and
  # the failing one is not always the last.
  local agent_log="" agent_pod="" job_terminal=""
  local deadline="${SUPERCRED_STUN_EVIDENCE_TIMEOUT:-120}"

  # Collect output while the Job is still alive. Waiting for its terminal
  # condition first races the controller deleting its failed pod. A restarted
  # container keeps the useful denial in `--previous`, so inspect both logs.
  local started_at=$SECONDS
  while :; do
    local agent_pods
    agent_pods="$(kubectl -n "$NAMESPACE_AGENTS" get pods -l job-name=supercred-agent-run \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || agent_pods=""
    for agent_pod in $agent_pods; do
      local current_log previous_log
      current_log="$(kubectl -n "$NAMESPACE_AGENTS" logs "$agent_pod" --all-containers --pod-running-timeout=1s 2>/dev/null)" \
        || current_log=""
      previous_log="$(kubectl -n "$NAMESPACE_AGENTS" logs "$agent_pod" --all-containers --previous --pod-running-timeout=1s 2>/dev/null)" \
        || previous_log=""
      # Only an agent's structured step lines are evidence. kubectl can print
      # a successful-looking CRI retrieval failure while a terminating pod has
      # already discarded its logs; never let that overwrite captured proof.
      [[ "$current_log" == *"[step-"* ]] && agent_log="$current_log"
      [[ "$previous_log" == *"[step-"* ]] && agent_log="$previous_log"
    done

    job_terminal="$(kubectl -n "$NAMESPACE_AGENTS" get job supercred-agent-run \
      -o "jsonpath={.status.conditions[?(@.type=='Complete')].status}{.status.conditions[?(@.type=='Failed')].status}" \
      2>/dev/null)" || job_terminal=""
    [[ "$job_terminal" == *True* ]] && break
    [ $((SECONDS - started_at)) -ge "$deadline" ] && break
    sleep 2
  done

  if [ "$(job_condition Complete)" = "True" ]; then
    fail "agent job COMPLETED after the stun — credentials were NOT revoked.
       Agent output:
$(printf '%s' "$agent_log" | indent)"
  fi

  [ -n "$agent_log" ] || fail "the stun is unproven: no output was captured from the agent job's pod
       within ${deadline}s. The Job did not succeed, but nothing here shows WHY,
       and 'did not succeed' is not evidence of credential revocation.
       Inspect: kubectl -n $NAMESPACE_AGENTS describe job supercred-agent-run"

  log "agent output after revocation (full, verbatim):"
  printf '%s\n' "$agent_log" | indent

  if printf '%s' "$agent_log" | grep -qiE 'FAILED.*(openbao|credential|token|login|permission denied|40[13])'; then
    ok "confirmed: the agent reached SPIFFE but was DENIED credentials — that is the stun"
  elif printf '%s' "$agent_log" | grep -q 'FAILED'; then
    # A failure at a different step means the demo broke, not that the stun
    # worked. Saying so beats claiming a revocation the output does not support.
    fail "the agent job failed, but NOT at the credential step, so this run does not
       prove revocation. Fix the underlying failure and re-run. Agent output:
$(printf '%s' "$agent_log" | indent)"
  else
    fail "the agent job did not succeed and did not report a failure — the stun is
       unproven. Agent output:
$(printf '%s' "$agent_log" | indent)"
  fi

  kubectl delete job supercred-agent-run -n "$NAMESPACE_AGENTS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  ok "step 4 complete — agent stunned, credentials revoked and proven revoked"
}

# ─── STEP 5: Teardown ───────────────────────────────────────────────────────

demo_5() {
  log "step 5: tearing down supercred demo resources"
  kubectl delete job openbao-supercred-bootstrap -n "$NAMESPACE_BAO" --ignore-not-found --wait=true 2>/dev/null || true

  # Delete from EVERY candidate namespace, not just the first one that matches.
  #
  # resolve_agent_pod_namespace returns the FIRST namespace holding the pod and
  # stops. But the pod can exist in BOTH: this script applies
  # agents-cardvault.yaml directly (landing it in fe-signalloom-agents, the
  # namespace the manifest declares) while Flux applies the same manifest
  # through a Kustomization whose targetNamespace puts it in fe-signalloom.
  # Teardown then deleted the fe-signalloom-agents copy, and the verification
  # below re-resolved, found the fe-signalloom copy, and failed with "agent pod
  # still exists" — a teardown that deleted a pod and then correctly reported
  # the demo was not clean. Sweeping every candidate is the fix; it is
  # idempotent, and --ignore-not-found makes the empty cases free.
  local ns
  for ns in "${AGENT_NAMESPACE_CANDIDATES[@]}"; do
    kubectl delete job supercred-agent-run -n "$ns" --ignore-not-found --wait=true 2>/dev/null || true
    kubectl delete pod agent-cardvault -n "$ns" --ignore-not-found --wait=true 2>/dev/null || true
    kubectl delete sa cardvault-agent -n "$ns" --ignore-not-found 2>/dev/null || true
  done
  # -n "$NAMESPACE_INFRA" is load-bearing and must MIRROR the apply in demo_1.
  # Neither kustomization sets a `namespace:`, so the namespace comes entirely
  # from the command line. demo_1 applies with `-n "$NAMESPACE_INFRA"`, which
  # lands the objects in inf-signalloom; this delete used to omit it, so it
  # targeted the kubeconfig's default namespace, matched nothing there, and
  # --ignore-not-found turned that into a silent exit 0. The cardvault and
  # policy-engine Deployments, Services and NetworkPolicy were therefore NEVER
  # torn down, which made `make demo-signalloom-supercred-all` unable to
  # complete: the verification below correctly failed on every single run.
  kubectl delete -k d2-signalloom/apps/cardvault/base/ -n "$NAMESPACE_INFRA" --ignore-not-found 2>/dev/null || true
  kubectl delete -k d2-signalloom/apps/policy-engine/base/ -n "$NAMESPACE_INFRA" --ignore-not-found 2>/dev/null || true

  local spire_pod
  spire_pod=$(spire_pod)
  if [ -n "$spire_pod" ]; then
    local entry_id
    entry_id=$(kubectl -n "$NAMESPACE_BAO" exec "$spire_pod" -- \
      /opt/spire/bin/spire-server entry show -spiffeID "$SPIFFE_ID" 2>/dev/null \
      | grep "Entry ID" | awk '{print $NF}') || true
    if [ -n "$entry_id" ]; then
      kubectl -n "$NAMESPACE_BAO" exec "$spire_pod" -- \
        /opt/spire/bin/spire-server entry delete -entryID "$entry_id" >/dev/null 2>&1 || true
    fi
  fi

  # Remove the credential material step 1 seeded.
  #
  # Teardown used to leave all three of these behind, because only step 4 ever
  # deleted any of them. Two consequences, both bad:
  #
  #   1. Aborting the demo anywhere before step 4 — which is what an operator
  #      does when something goes wrong on stage — left a LIVE, readable
  #      credential in the vault, on a demo whose entire subject is credential
  #      revocation.
  #   2. `bao kv delete` is a SOFT delete: it leaves the version history and
  #      `bao kv undelete` brings the secret straight back. Even after a
  #      complete 1→5 run the credential was recoverable. `kv metadata delete`
  #      is what actually removes it.
  #
  # The policy was never deleted by anything at all, at any point.
  log "removing OpenBao credential material"
  bao_exec() {
    kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
      env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token "$@" \
      >/dev/null 2>&1
  }
  bao_exec bao kv metadata delete kv/signalloom/cardvault-agent || true
  bao_exec bao delete auth/jwt/role/signalloom-cardvault-agent || true
  bao_exec bao policy delete signalloom-cardvault-agent || true

  # Verify clean
  log "verifying teardown..."
  kubectl -n "$NAMESPACE_INFRA" get deployment cardvault 2>/dev/null && fail "cardvault still exists after teardown"
  kubectl -n "$NAMESPACE_INFRA" get deployment policy-engine 2>/dev/null && fail "policy-engine still exists after teardown"
  resolve_agent_pod_namespace \
    && fail "agent pod still exists in $AGENT_POD_NAMESPACE after teardown"

  # Verify the credential material too — this is a credential demo, and a
  # teardown that only checks Deployments is not verifying the thing that
  # matters. `bao kv get` is deliberately NOT used here: it exits 0 against a
  # soft-deleted secret, so it cannot tell "removed" from "recoverable".
  bao_exec bao kv metadata get kv/signalloom/cardvault-agent \
    && fail "OpenBao secret kv/signalloom/cardvault-agent still exists after teardown"
  bao_exec bao read auth/jwt/role/signalloom-cardvault-agent \
    && fail "OpenBao JWT role signalloom-cardvault-agent still exists after teardown"
  bao_exec bao policy read signalloom-cardvault-agent \
    && fail "OpenBao policy signalloom-cardvault-agent still exists after teardown"

  ok "step 5 complete — teardown verified (workloads and credential material)"
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

run_all() {
  log "running full demo cycle (steps 1→5)"
  demo_1
  demo_2
  demo_3
  demo_4
  demo_5
  ok "full demo cycle complete"
}

case "${1:-}" in
  1) demo_1 ;;
  2) demo_2 ;;
  3) demo_3 ;;
  4) demo_4 ;;
  5) demo_5 ;;
  all) run_all ;;
  *)
    echo "Usage: $0 {1|2|3|4|5|all}" >&2
    echo ""
    echo "  1    Deploy services, agent, OpenBao secrets, SPIRE entry"
    echo "  2    Run SPIFFE → OpenBao → cardvault credential chain"
    echo "  3    Compliance scan — discovers missing securityContext"
    echo "  4    Stun: revoke credentials, verify denial"
    echo "  5    Teardown + verify clean"
    echo "  all  Run 1→5 sequentially"
    exit 1
    ;;
esac
