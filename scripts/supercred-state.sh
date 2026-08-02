#!/usr/bin/env bash
# supercred-state.sh — observe and assert the SuperCred demo's cluster state.
#
#   supercred-state.sh probe                  # emit the full state as key=value
#   supercred-state.sh assert-clean [FILE]    # assert nothing the demo creates remains
#   supercred-state.sh assert-deployed [FILE] # assert step-1 resources are present
#   supercred-state.sh assert-step N [FILE]   # assert the state after step N (1..5)
#   supercred-state.sh reset                  # DEEP reset — remove everything, incl.
#                                             # the residue `supercred-demo.sh 5` leaves
#
# ─── Why this exists separately from supercred-demo.sh ──────────────────────
#
# `supercred-demo.sh 5` verifies teardown by checking three things: the two
# Deployments and the agent Pod. That is a strict subset of what the demo
# creates. Everything else it leaves behind is invisible to it:
#
#   * the OpenBao KV secret kv/signalloom/cardvault-agent   (step 1 seeds it;
#     only step 4 deletes it, so ANY reset before step 4 leaks it)
#   * the OpenBao JWT role auth/jwt/role/signalloom-cardvault-agent  (same)
#   * the OpenBao policy signalloom-cardvault-agent  (step 1 writes it and
#     NOTHING ever deletes it — not step 4, not step 5)
#   * the supercred-agent-run Job
#   * the cardvault-agent ServiceAccount
#   * the SPIRE registration entry
#
# A demo that is about credential revocation cannot credibly assert "clean" while
# the credential material it revoked in step 4 is still sitting in the vault
# after a step-3 abort. So state observation is factored out here, as a PURE
# function over an observed state document:
#
#   probe   — talks to the cluster, emits key=value lines, asserts nothing
#   assert-* — reads key=value lines, talks to nothing, decides pass/fail
#
# That split is what makes the assertions testable. Feeding a fixture file to
# `assert-clean` proves it goes red for the right reason without needing a
# cluster, a demo run, or three minutes — see test/supercred-state.bats, which
# drives every failure mode this way.
#
# ─── Injectable boundaries ──────────────────────────────────────────────────
#   KUBECTL       kubectl binary (default: kubectl) — point at a fake to test probe
#   PROBE_TIMEOUT per-call timeout in seconds (default: 15)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBECTL="${KUBECTL:-kubectl}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-15}"

NAMESPACE_INFRA="${NAMESPACE_INFRA:-inf-signalloom}"
NAMESPACE_BAO="${NAMESPACE_BAO:-inf-bao}"
NAMESPACE_AGENTS="${NAMESPACE_AGENTS:-fe-signalloom-agents}"
SPIFFE_ID="${SPIFFE_ID:-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent}"
BAO_TOKEN="${BAO_TOKEN:-signalloom-demo-root-token}"

# agents-cardvault.yaml says `namespace: fe-signalloom-agents`, but the Flux
# Kustomization's targetNamespace can relocate the pod to fe-signalloom. Probe
# both, exactly as supercred-demo.sh's resolve_agent_pod_namespace does.
IFS=' ' read -r -a AGENT_NAMESPACE_CANDIDATES \
  <<< "${AGENT_NAMESPACE_CANDIDATES:-fe-signalloom-agents fe-signalloom}"

log()  { printf '\033[1;36m[supercred-state]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[supercred-state] ✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[supercred-state] !\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[supercred-state] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

k() { timeout "$PROBE_TIMEOUT" "$KUBECTL" "$@"; }

# ─── Probe ──────────────────────────────────────────────────────────────────

# present/absent for an object's existence. Never fails the script.
exists() {
  local kind="$1" name="$2" ns="${3:-}"
  local args=(get "$kind" "$name")
  [ -n "$ns" ] && args+=(-n "$ns")
  if k "${args[@]}" >/dev/null 2>&1; then printf 'present'; else printf 'absent'; fi
}

# Runs a `bao` command inside the OpenBao pod. Returns its exit status.
bao_exec() {
  k -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$BAO_TOKEN" "$@" >/dev/null 2>&1
}

spire_pod() {
  k -n "$NAMESPACE_BAO" get pod -l app.kubernetes.io/name=spire-server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

probe() {
  local agent_ns="" ns

  # ── Kubernetes objects ──
  printf 'k8s.cardvault_deployment=%s\n' "$(exists deployment cardvault "$NAMESPACE_INFRA")"
  printf 'k8s.policy_engine_deployment=%s\n' "$(exists deployment policy-engine "$NAMESPACE_INFRA")"
  printf 'k8s.cardvault_service=%s\n' "$(exists service cardvault "$NAMESPACE_INFRA")"
  printf 'k8s.policy_engine_service=%s\n' "$(exists service policy-engine "$NAMESPACE_INFRA")"

  for ns in "${AGENT_NAMESPACE_CANDIDATES[@]}"; do
    if [ "$(exists pod agent-cardvault "$ns")" = present ]; then agent_ns="$ns"; break; fi
  done
  if [ -n "$agent_ns" ]; then
    printf 'k8s.agent_pod=present\n'
    printf 'k8s.agent_pod_namespace=%s\n' "$agent_ns"
    printf 'k8s.agent_pod_state=%s\n' \
      "$(k -n "$agent_ns" get pod agent-cardvault \
          -o jsonpath='{.metadata.labels.signalloom\.ai/state}' 2>/dev/null || true)"
    printf 'k8s.agent_pod_phase=%s\n' \
      "$(k -n "$agent_ns" get pod agent-cardvault \
          -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  else
    printf 'k8s.agent_pod=absent\n'
    printf 'k8s.agent_pod_namespace=\n'
    printf 'k8s.agent_pod_state=\n'
    printf 'k8s.agent_pod_phase=\n'
  fi

  # The ServiceAccount follows the pod: agents-cardvault-sa.yaml declares
  # fe-signalloom-agents, but the Flux Kustomization's targetNamespace can
  # relocate it exactly as it relocates the pod. Probing only the declared
  # namespace reports 'absent' for an SA that is alive one namespace over —
  # which reads as a clean teardown when nothing was torn down.
  local sa_state=absent
  for ns in "${AGENT_NAMESPACE_CANDIDATES[@]}"; do
    if [ "$(exists sa cardvault-agent "$ns")" = present ]; then sa_state=present; break; fi
  done
  printf 'k8s.agent_sa=%s\n' "$sa_state"
  printf 'k8s.agent_job=%s\n' "$(exists job supercred-agent-run "$NAMESPACE_AGENTS")"
  printf 'k8s.bootstrap_job=%s\n' "$(exists job openbao-supercred-bootstrap "$NAMESPACE_BAO")"

  # ── OpenBao credential material ──
  # These three are the entire point of a credential demo. `supercred-demo.sh 5`
  # observes none of them.
  #
  # kv_secret is THREE-valued, not a boolean, because KV v2 has three states and
  # collapsing them hides the answer to the only question that matters. `bao kv
  # delete` is a SOFT delete: it writes a deletion marker, leaves the version
  # history intact, and the secret can be brought back with `bao kv undelete`.
  # Critically, `bao kv get` still EXITS 0 against a soft-deleted secret — it
  # returns `"data": null` with a `deletion_time`. A probe built on `bao kv get`
  # therefore reports a revoked credential as still present, which is how this
  # check first (wrongly) accused step 4 of failing to revoke anything.
  # `-field=username` exits non-zero unless real data is readable, which is the
  # actual security question: can the credential still be read?
  if bao_exec bao kv get -field=username kv/signalloom/cardvault-agent; then
    printf 'bao.kv_secret=readable\n'
  elif bao_exec bao kv metadata get kv/signalloom/cardvault-agent; then
    # Revoked but recoverable: `bao kv undelete` restores it. Adequate for
    # step 4's revocation, NOT clean for teardown.
    printf 'bao.kv_secret=soft-deleted\n'
  else
    printf 'bao.kv_secret=absent\n'
  fi
  if bao_exec bao read auth/jwt/role/signalloom-cardvault-agent; then
    printf 'bao.jwt_role=present\n'
  else
    printf 'bao.jwt_role=absent\n'
  fi
  if bao_exec bao policy read signalloom-cardvault-agent; then
    printf 'bao.policy=present\n'
  else
    printf 'bao.policy=absent\n'
  fi

  # ── SPIRE registration ──
  local sp entries
  sp="$(spire_pod)"
  if [ -z "$sp" ]; then
    printf 'spire.reachable=false\n'
    printf 'spire.entry=unknown\n'
  else
    printf 'spire.reachable=true\n'
    entries="$(k -n "$NAMESPACE_BAO" exec "$sp" -- \
      /opt/spire/bin/spire-server entry show -spiffeID "$SPIFFE_ID" 2>/dev/null || true)"
    # `entry show` prints "Found 0 entries" for a clean server; any Entry ID
    # line means a registration survives.
    if printf '%s' "$entries" | grep -q 'Entry ID'; then
      printf 'spire.entry=present\n'
    else
      printf 'spire.entry=absent\n'
    fi
  fi

  # ── Flux ──
  # agents-cardvault{,-sa,-job}.yaml are members of the Flux-managed
  # fe-signalloom `apps` Kustomization (d2-signalloom/apps/fe-signalloom/base/
  # kustomization.yaml lines 24-26). A teardown is therefore only durable until
  # the next reconcile — which is why "clean" and "stays clean" are two
  # different questions, and why assert-clean reports this separately.
  printf 'flux.fe_signalloom_suspended=%s\n' \
    "$(k -n fe-signalloom get kustomization apps -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
  printf 'flux.fe_signalloom_interval=%s\n' \
    "$(k -n fe-signalloom get kustomization apps -o jsonpath='{.spec.interval}' 2>/dev/null || true)"

  # inf-bao/infra-configs owns openbao-supercred-bootstrap.yaml, which carries
  # kustomize.toolkit.fluxcd.io/force: "true" — so every reconcile DELETES AND
  # RECREATES that Job, and the Job re-runs:
  #     bao policy write signalloom-cardvault-agent
  #     bao write   auth/jwt/role/signalloom-cardvault-agent
  #     bao kv put  kv/signalloom/cardvault-agent
  # which is EXACTLY the three objects step 4 revokes. On a 30m interval the
  # demo therefore has a recurring window in which the stun is silently undone
  # and the agent authenticates successfully straight after being "revoked" —
  # observed live: the inf-bao reconcile transitioned Ready at 16:23:58Z and
  # step 4 failed with "credentials were not revoked" in that same second.
  printf 'flux.inf_bao_suspended=%s\n' \
    "$(k -n inf-bao get kustomization infra-configs -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
  printf 'flux.inf_bao_interval=%s\n' \
    "$(k -n inf-bao get kustomization infra-configs -o jsonpath='{.spec.interval}' 2>/dev/null || true)"
}

# ─── Assertions (pure — read state, touch nothing) ──────────────────────────

# Reads key=value lines from $1 (file) or stdin into the STATE assoc array.
declare -A STATE
load_state() {
  local src="${1:--}" line key value
  STATE=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    STATE["$key"]="$value"
  done < <(if [ "$src" = "-" ]; then cat; else cat "$src"; fi)
  [ "${#STATE[@]}" -gt 0 ] || fail "no state read from ${src} — probe produced nothing"
}

VIOLATIONS=()

# expect <key> <expected> <human explanation of what a mismatch means>
expect() {
  local key="$1" want="$2" why="$3" got="${STATE[$1]-<unset>}"
  if [ "$got" != "$want" ]; then
    VIOLATIONS+=("$key: expected '$want', got '$got' — $why")
  fi
}

# expect_not <key> <forbidden> <human explanation> — for guarantees that are
# "anything but X". Step 4 must leave the credential unreadable; whether it got
# there by soft delete or hard destroy is not the demo's promise, so asserting a
# single exact value there would encode an implementation detail as a
# requirement and break the moment revocation is tightened.
expect_not() {
  local key="$1" forbidden="$2" why="$3" got="${STATE[$1]-<unset>}"
  if [ "$got" = "$forbidden" ] || [ "$got" = "<unset>" ]; then
    VIOLATIONS+=("$key: must not be '$forbidden', got '$got' — $why")
  fi
}

report() {
  local what="$1" v
  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\033[1;31m[supercred-state] FAILED:\033[0m %s\n' "$what" >&2
    for v in "${VIOLATIONS[@]}"; do printf '  ✗ %s\n' "$v" >&2; done
    return 1
  fi
  ok "$what"
  return 0
}

assert_clean() {
  load_state "${1:--}"
  VIOLATIONS=()

  expect k8s.cardvault_deployment absent "cardvault Deployment survived teardown"
  expect k8s.policy_engine_deployment absent "policy-engine Deployment survived teardown"
  expect k8s.cardvault_service absent "cardvault Service survived teardown"
  expect k8s.policy_engine_service absent "policy-engine Service survived teardown"
  expect k8s.agent_pod absent "agent-cardvault Pod survived teardown"
  expect k8s.agent_sa absent "cardvault-agent ServiceAccount survived teardown"
  expect k8s.agent_job absent "supercred-agent-run Job survived teardown"

  # The credential material. This is the part supercred-demo.sh 5 never looks at.
  # 'absent', not merely 'not readable': a soft-deleted secret keeps its version
  # history and comes back with `bao kv undelete`, so teardown has not actually
  # removed the credential. Only `bao kv metadata delete` does.
  expect bao.kv_secret absent \
    "OpenBao KV secret kv/signalloom/cardvault-agent survived teardown (only step 4 deletes it — a reset before step 4 leaks live credentials — and step 4's delete is a recoverable SOFT delete that leaves the version history behind)"
  expect bao.jwt_role absent \
    "OpenBao JWT role signalloom-cardvault-agent survived teardown (only step 4 deletes it)"
  expect bao.policy absent \
    "OpenBao policy signalloom-cardvault-agent survived teardown (NOTHING in the demo ever deletes this)"

  expect spire.entry absent "SPIRE registration entry for $SPIFFE_ID survived teardown"

  report "state is clean — every object the demo creates is gone"
}

assert_deployed() {
  load_state "${1:--}"
  VIOLATIONS=()

  expect k8s.cardvault_deployment present "cardvault Deployment missing — step 1 did not complete"
  expect k8s.policy_engine_deployment present "policy-engine Deployment missing — step 1 did not complete"
  expect k8s.agent_pod present "agent-cardvault Pod missing — step 1 did not complete"
  expect bao.kv_secret readable "OpenBao KV secret unreadable — step 1 did not seed credentials"
  expect bao.jwt_role present "OpenBao JWT role missing — step 1 did not seed the auth role"
  expect bao.policy present "OpenBao policy missing — step 1 did not write it"
  expect spire.entry present "SPIRE entry missing — step 1 did not register the workload"

  report "state is deployed — step 1 postconditions all hold"
}

# The demo's own step preflights only ever check the pod label. These assert the
# full postcondition of each step, which is what makes an interrupted run
# detectable rather than merely unlucky.
assert_step() {
  local step="$1"
  load_state "${2:--}"
  VIOLATIONS=()

  case "$step" in
    1)
      expect k8s.cardvault_deployment present "step 1 must deploy cardvault"
      expect k8s.policy_engine_deployment present "step 1 must deploy policy-engine"
      expect k8s.agent_pod present "step 1 must create the agent pod"
      expect bao.kv_secret readable "step 1 must seed a readable KV secret"
      expect bao.jwt_role present "step 1 must write the JWT role"
      expect spire.entry present "step 1 must register the SPIRE entry"
      ;;
    2)
      expect k8s.agent_pod present "step 2 needs the agent pod"
      expect k8s.agent_pod_state active "step 2 must label the agent active after the credential chain"
      expect bao.kv_secret readable "step 2 must not disturb the seeded credential"
      ;;
    3)
      expect k8s.agent_pod present "step 3 needs the agent pod"
      expect k8s.agent_pod_state non-compliant \
        "step 3 must label the agent non-compliant — the missing securityContext is the whole point of the scan"
      expect bao.kv_secret readable "step 3 must not revoke anything — that is step 4's job"
      ;;
    4)
      expect k8s.agent_pod present "step 4 leaves the pod in place, stunned"
      expect k8s.agent_pod_state stunned "step 4 must label the agent stunned"
      expect_not bao.kv_secret readable "step 4 must revoke the KV secret — if it is still readable the stun did nothing"
      expect bao.jwt_role absent "step 4 must revoke the JWT auth role"
      expect k8s.agent_job absent "step 4 must clean up the verification Job it created"
      ;;
    5)
      assert_clean "${2:--}"
      return $?
      ;;
    *) fail "unknown step '$step' — expected 1..5" ;;
  esac

  report "state matches the postcondition of step $step"
}

# Flux owns agents-cardvault{,-sa,-job}.yaml, so a teardown that looks clean now
# is undone at the next reconcile. Separate check, separate verdict — conflating
# the two is how "it was clean when I checked" turns into a broken live demo.
assert_stays_clean() {
  load_state "${1:--}"
  VIOLATIONS=()
  if [ "${STATE[flux.fe_signalloom_suspended]-}" != "true" ]; then
    VIOLATIONS+=("flux.fe_signalloom_suspended: expected 'true', got '${STATE[flux.fe_signalloom_suspended]-<unset>}' — the fe-signalloom apps Kustomization (interval ${STATE[flux.fe_signalloom_interval]-?}) will re-create agent-cardvault, its ServiceAccount and the supercred-agent-run Job, because all three are members of d2-signalloom/apps/fe-signalloom/base/kustomization.yaml. Teardown is not durable while it reconciles.")
  fi
  report "teardown is durable — Flux will not resurrect the demo objects"
}

# The revocation in step 4 is the demo's climax and the one claim an auditor
# would actually test. It is undone by a Flux reconcile of inf-bao, so "is the
# stun safe right now?" is a real, answerable question with an operational
# answer: suspend inf-bao/infra-configs for the length of the demo.
assert_no_reseed() {
  load_state "${1:--}"
  VIOLATIONS=()
  if [ "${STATE[flux.inf_bao_suspended]-}" != "true" ]; then
    VIOLATIONS+=("flux.inf_bao_suspended: expected 'true', got '${STATE[flux.inf_bao_suspended]-<unset>}' — the inf-bao infra-configs Kustomization (interval ${STATE[flux.inf_bao_interval]-?}) recreates openbao-supercred-bootstrap on every reconcile (it is annotated force: \"true\"), and that Job re-writes the policy, the JWT role and the KV secret that step 4 revokes. Until it is suspended, the stun can be silently undone mid-demo. Mitigate with: kubectl -n inf-bao patch kustomization infra-configs --type=merge -p '{\"spec\":{\"suspend\":true}}'")
  fi
  report "the stun cannot be undone by a Flux reconcile"
}

# ─── Deep reset ─────────────────────────────────────────────────────────────

# Everything `supercred-demo.sh 5` does, plus the credential material and the
# Job it forgets. Idempotent, and safe to invoke at any point in the demo —
# including halfway through step 3, which is the case the numbered steps handle
# worst.
deep_reset() {
  log "deep reset: removing every object the SuperCred demo creates"

  "${SCRIPT_DIR}/supercred-demo.sh" 5 >/dev/null 2>&1 \
    || warn "supercred-demo.sh 5 exited non-zero — continuing with the residue sweep"

  local ns
  for ns in "${AGENT_NAMESPACE_CANDIDATES[@]}"; do
    k delete pod agent-cardvault -n "$ns" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    k delete job supercred-agent-run -n "$ns" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    k delete sa cardvault-agent -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  done

  # The residue supercred-demo.sh 5 leaves untouched.
  bao_exec bao kv delete kv/signalloom/cardvault-agent || true
  bao_exec bao kv metadata delete kv/signalloom/cardvault-agent || true
  bao_exec bao delete auth/jwt/role/signalloom-cardvault-agent || true
  bao_exec bao policy delete signalloom-cardvault-agent || true

  local sp entry_id
  sp="$(spire_pod)"
  if [ -n "$sp" ]; then
    while :; do
      entry_id="$(k -n "$NAMESPACE_BAO" exec "$sp" -- \
        /opt/spire/bin/spire-server entry show -spiffeID "$SPIFFE_ID" 2>/dev/null \
        | awk '/Entry ID/ {print $NF; exit}')" || true
      [ -n "$entry_id" ] || break
      k -n "$NAMESPACE_BAO" exec "$sp" -- \
        /opt/spire/bin/spire-server entry delete -entryID "$entry_id" >/dev/null 2>&1 || break
    done
  fi

  ok "deep reset complete"
}

# ─── Dispatch ───────────────────────────────────────────────────────────────

case "${1:-}" in
  probe)          probe ;;
  assert-clean)   assert_clean "${2:--}" ;;
  assert-deployed) assert_deployed "${2:--}" ;;
  assert-step)    assert_step "${2:?step required}" "${3:--}" ;;
  assert-stays-clean) assert_stays_clean "${2:--}" ;;
  assert-no-reseed)   assert_no_reseed "${2:--}" ;;
  reset)          deep_reset ;;
  *)
    cat >&2 <<'USAGE'
Usage: supercred-state.sh <command> [args]

  probe                    Emit the observed SuperCred state as key=value lines
  assert-clean [FILE]      Assert no demo-created object remains (FILE or stdin)
  assert-deployed [FILE]   Assert step-1 postconditions hold
  assert-step N [FILE]     Assert the postcondition of step N (1..5)
  assert-stays-clean [FILE] Assert Flux will not resurrect the demo objects
  reset                    Deep reset — teardown plus the residue step 5 misses

Assertions read state; they never touch the cluster. Pipe probe into them:
  supercred-state.sh probe | supercred-state.sh assert-clean
USAGE
    exit 1
    ;;
esac
