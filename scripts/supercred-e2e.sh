#!/usr/bin/env bash
# supercred-e2e.sh — tier 2. Prove the SuperCred demo works REPEATEDLY.
#
#   supercred-e2e.sh iterate [N]      # N full 1→5 cycles, postcondition-checked
#   supercred-e2e.sh iterate-all [N]  # N cycles via `make …-supercred-all`
#   supercred-e2e.sh midrun-reset     # reset halfway through step 3, then recover
#   supercred-e2e.sh all [N]          # iterate N, iterate-all N, midrun-reset
#
# ─── Why three iterations ───────────────────────────────────────────────────
#
# One clean pass proves the demo can work once on a cluster in whatever state it
# happened to be in. It says nothing about whether it works AGAIN — which is the
# only property that matters when demoing live, because the presenter has
# invariably run it in rehearsal an hour earlier. Repeatability failures come
# from state the teardown missed, and they are invisible on run 1 by
# construction: run 1 is the one that creates the state. Run 2 is the first that
# can trip over it, and run 3 is what distinguishes "converged" from "alternating
# between two broken states". Three consecutive clean iterations is the bar.
#
# Every iteration asserts the postcondition of every step (via
# supercred-state.sh, whose assertions are unit-proven to go red in
# test/supercred-state.bats), not merely that the step exited 0. A step that
# exits 0 having done nothing is the failure mode this repo keeps shipping.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE="${SCRIPT_DIR}/supercred-state.sh"
DEMO="${SCRIPT_DIR}/supercred-demo.sh"

RUN_DIR="${SUPERCRED_E2E_RUN_DIR:-${REPO_ROOT}/test-results/supercred-e2e}"
mkdir -p "$RUN_DIR"

ITERATIONS="${SUPERCRED_E2E_ITERATIONS:-3}"

log()  { printf '\033[1;36m[e2e]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;35m[e2e] ══ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[e2e] ✓\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[e2e] ✗\033[0m %s\n' "$*" >&2; }
fail() { bad "$*"; exit 1; }

FAILURES=()
record_failure() { FAILURES+=("$1"); bad "$1"; }

# Capture the state to a file and assert against it, keeping the evidence.
# Two arguments so the log name says which moment it captured.
capture() {
  local label="$1" out="${RUN_DIR}/${1}.state"
  "$STATE" probe >"$out" 2>"${RUN_DIR}/${label}.probe.log" \
    || { bad "probe failed at ${label} (see ${RUN_DIR}/${label}.probe.log)"; return 1; }
  printf '%s' "$out"
}

# assert_at <label> <assert-subcommand> [step-number]
assert_at() {
  local label="$1"; shift
  local snapshot
  snapshot="$(capture "$label")" || { record_failure "${label}: probe failed"; return 1; }
  if "$STATE" "$@" "$snapshot"; then
    return 0
  fi
  record_failure "${label}: $* failed (state: $snapshot)"
  return 1
}

run_step() {
  local n="$1" label="$2"
  log "running demo step ${n}"
  if ! "$DEMO" "$n" >"${RUN_DIR}/${label}.step${n}.log" 2>&1; then
    bad "demo step ${n} exited non-zero — tail:"
    tail -25 "${RUN_DIR}/${label}.step${n}.log" >&2 || true
    record_failure "${label}: demo step ${n} exited non-zero"
    return 1
  fi
  return 0
}

# ─── Flux pinning ───────────────────────────────────────────────────────────
#
# Two Flux Kustomizations actively fight this demo:
#
#   inf-bao/infra-configs      owns openbao-supercred-bootstrap.yaml, annotated
#                              kustomize.toolkit.fluxcd.io/force: "true", so
#                              every reconcile deletes and RECREATES that Job —
#                              which re-writes the OpenBao policy, the JWT role
#                              and the KV secret that step 4 revokes. A
#                              reconcile landing during step 4 silently un-does
#                              the stun and the agent authenticates
#                              successfully. Observed: reconcile Ready at
#                              16:23:58Z, step 4 failed "credentials were not
#                              revoked" in the same second.
#
#   fe-signalloom/apps         owns agents-cardvault{,-sa,-job}.yaml, so it
#                              resurrects the agent pod, its ServiceAccount and
#                              the run Job after teardown.
#
# Both are suspended for the duration of the run and restored on exit, so that
# what gets measured is the DEMO's repeatability rather than a race with the
# reconciler. Set SUPERCRED_E2E_PIN_FLUX=0 to measure the demo as an operator
# would actually experience it, reconciler included.
PIN_FLUX="${SUPERCRED_E2E_PIN_FLUX:-1}"
PINNED=()
PINNED_SETS=()

# The Kustomizations are not the top of the ownership chain. They are generated
# by flux-operator ResourceSets (label
# resourceset.fluxcd.controlplane.io/name), and signalloom-infra carries
# `fluxcd.controlplane.io/reconcileEvery: 5m`. So `spec.suspend=true` on
# inf-bao/infra-configs is reverted within five minutes by the ResourceSet, even
# with the parent flux-system Kustomization suspended — which is exactly how a
# run could report "suspended (verified)" at preflight and still be re-seeded by
# iteration 3. Disabling reconciliation at the ResourceSet is the only pin that
# actually holds.
RESOURCESETS=(flux-system/signalloom-infra flux-system/signalloom-apps)
RECONCILE_ANNOTATION="fluxcd.controlplane.io/reconcile"

flux_set_suspend() {
  local ns="$1" name="$2" value="$3"
  kubectl -n "$ns" patch kustomization "$name" --type=merge \
    -p "{\"spec\":{\"suspend\":${value}}}" >/dev/null 2>&1
}

resourceset_set_reconcile() {
  local ns="$1" name="$2" value="$3"
  if [ "$value" = "enabled" ]; then
    kubectl -n "$ns" annotate resourceset "$name" "${RECONCILE_ANNOTATION}-" \
      --overwrite >/dev/null 2>&1
  else
    kubectl -n "$ns" annotate resourceset "$name" "${RECONCILE_ANNOTATION}=disabled" \
      --overwrite >/dev/null 2>&1
  fi
}

restore_flux() {
  local entry ns name
  for entry in "${PINNED[@]:-}"; do
    [ -n "$entry" ] || continue
    ns="${entry%%/*}"; name="${entry##*/}"
    if flux_set_suspend "$ns" "$name" false; then
      log "restored Flux reconciliation for ${ns}/${name}"
    else
      bad "FAILED to restore Flux reconciliation for ${ns}/${name} — run: kubectl -n ${ns} patch kustomization ${name} --type=merge -p '{\"spec\":{\"suspend\":false}}'"
    fi
  done
  for entry in "${PINNED_SETS[@]:-}"; do
    [ -n "$entry" ] || continue
    ns="${entry%%/*}"; name="${entry##*/}"
    if resourceset_set_reconcile "$ns" "$name" enabled; then
      log "restored ResourceSet reconciliation for ${ns}/${name}"
    else
      bad "FAILED to restore ResourceSet ${ns}/${name} — run: kubectl -n ${ns} annotate resourceset ${name} ${RECONCILE_ANNOTATION}-"
    fi
  done
  PINNED=(); PINNED_SETS=()
}
# Restore on ANY exit, including Ctrl-C. Leaving a shared cluster's reconciler
# suspended because a test run was interrupted is a worse outcome than the
# flakiness being measured.
trap restore_flux EXIT INT TERM

pin_flux() {
  [ "$PIN_FLUX" = "1" ] || { log "Flux pinning disabled — reconciler races are in scope"; return 0; }
  local entry ns name
  # flux-system/flux-system MUST come first, and suspending the two leaf
  # Kustomizations without it does not work.
  #
  # The Kustomization objects are themselves Flux-managed: flux-system owns
  # clusters/local, which declares inf-bao/infra-configs and fe-signalloom/apps.
  # `kubectl patch ... spec.suspend=true` is therefore drift, and the parent
  # reconciles it away on its 10m interval — silently, and with no error
  # anywhere. Observed exactly this: preflight reported both leaves suspended,
  # and the state captured after step 4 showed
  # flux.inf_bao_suspended= (empty) with the KV secret, JWT role and policy all
  # re-seeded and openbao-supercred-bootstrap present again. The pin looked
  # applied and had already been undone.
  #
  # This is also the operational answer for anyone stabilising the demo by hand:
  # suspending the leaf Kustomization is not enough, because the thing that
  # manages the leaf will put it back.
  # ResourceSets first — they are what would undo the Kustomization pin.
  for entry in "${RESOURCESETS[@]}"; do
    ns="${entry%%/*}"; name="${entry##*/}"
    if resourceset_set_reconcile "$ns" "$name" disabled; then
      PINNED_SETS+=("$entry")
      log "disabled ResourceSet reconciliation for ${ns}/${name} (restored on exit)"
    else
      bad "could not disable ResourceSet ${ns}/${name} — the Kustomization pin will be reverted"
    fi
  done

  for entry in flux-system/flux-system inf-bao/infra-configs fe-signalloom/apps; do
    ns="${entry%%/*}"; name="${entry##*/}"
    flux_set_suspend "$ns" "$name" true || true
    # Read the value back. A patch that "succeeded" and was then reverted is
    # indistinguishable from one that held, unless you look — and looking is
    # the entire difference between measuring the demo and measuring a race.
    if [ "$(kubectl -n "$ns" get kustomization "$name" \
              -o jsonpath='{.spec.suspend}' 2>/dev/null)" = "true" ]; then
      PINNED+=("$entry")
      log "suspended Flux reconciliation for ${ns}/${name} (verified; restored on exit)"
    else
      bad "could not suspend ${ns}/${name} — the pin did not take, reconciler races remain possible"
      record_failure "Flux pin for ${ns}/${name} did not take effect"
    fi
  done
}

# Re-assert the pin before each iteration and report if it slipped. Cheap, and
# it converts "the run was mysteriously flaky" into "the pin came off at
# iteration 2".
verify_pin() {
  [ "$PIN_FLUX" = "1" ] || return 0
  local entry ns name
  for entry in "${PINNED[@]:-}"; do
    [ -n "$entry" ] || continue
    ns="${entry%%/*}"; name="${entry##*/}"
    if [ "$(kubectl -n "$ns" get kustomization "$name" \
              -o jsonpath='{.spec.suspend}' 2>/dev/null)" != "true" ]; then
      bad "Flux pin for ${ns}/${name} came off mid-run — re-applying"
      flux_set_suspend "$ns" "$name" true || true
    fi
  done
}

# ─── Preflight ──────────────────────────────────────────────────────────────

preflight() {
  step "preflight"
  command -v kubectl >/dev/null || fail "kubectl not on PATH"
  kubectl cluster-info >/dev/null 2>&1 || fail "cluster not reachable"
  pin_flux
  (cd "$REPO_ROOT" && make demo-signalloom-supercred-images >"${RUN_DIR}/images.log" 2>&1) \
    || fail "image build/load failed — see ${RUN_DIR}/images.log"
  ok "cluster reachable, images present"

  # Report Flux durability up front rather than as a mystery failure later. Not
  # fatal: it changes how a teardown result must be read, it does not invalidate
  # the run.
  local snapshot
  snapshot="$(capture preflight)" || fail "initial probe failed"
  if ! "$STATE" assert-stays-clean "$snapshot" 2>/dev/null; then
    log "NOTE: the fe-signalloom apps Kustomization is live; Flux may re-create"
    log "      agent-cardvault / its SA / the run Job between iterations."
  fi
}

# ─── One full iteration ─────────────────────────────────────────────────────

iteration() {
  # Two `local`s deliberately: in a single `local i=… label="iter${i}"` the
  # expansion of $i happens before the assignment to i takes effect, so every
  # iteration would write its evidence to the same "iter" prefix and silently
  # overwrite the previous run's snapshots.
  local i="$1"
  local label="iter${i}"
  step "iteration ${i}/${ITERATIONS} — steps 1→5"
  verify_pin

  # Always start from a genuinely clean slate, otherwise iteration 1 measures
  # whatever the previous session left behind rather than the demo.
  "$STATE" reset >"${RUN_DIR}/${label}.pre-reset.log" 2>&1 || true
  assert_at "${label}.00-preclean" assert-clean \
    || bad "iteration ${i} did not start clean — results below are about recovery, not a fresh run"

  run_step 1 "$label" || return 1
  assert_at "${label}.01-after-step1" assert-step 1 || return 1

  run_step 2 "$label" || return 1
  assert_at "${label}.02-after-step2" assert-step 2 || return 1

  run_step 3 "$label" || return 1
  assert_at "${label}.03-after-step3" assert-step 3 || return 1

  run_step 4 "$label" || return 1
  assert_at "${label}.04-after-step4" assert-step 4 || return 1

  run_step 5 "$label" || return 1
  # Step 5's own verification checks two Deployments and a Pod. This checks
  # everything the demo creates, which is where the leaks are.
  assert_at "${label}.05-after-step5" assert-clean || return 1

  ok "iteration ${i} complete and clean"
  return 0
}

iterate() {
  local n="${1:-$ITERATIONS}" i passed=0
  ITERATIONS="$n"
  preflight
  for i in $(seq 1 "$n"); do
    if iteration "$i"; then passed=$((passed + 1)); fi
  done
  step "iterate: ${passed}/${n} iterations clean"
  [ "$passed" -eq "$n" ]
}

# ─── Full-cycle target (`make …-supercred-all`) ─────────────────────────────

iterate_all() {
  local n="${1:-$ITERATIONS}" i passed=0 label
  preflight
  for i in $(seq 1 "$n"); do
    label="all${i}"
    step "make demo-signalloom-supercred-all — cycle ${i}/${n}"
    "$STATE" reset >"${RUN_DIR}/${label}.pre-reset.log" 2>&1 || true
    if (cd "$REPO_ROOT" && make demo-signalloom-supercred-all) \
        >"${RUN_DIR}/${label}.log" 2>&1; then
      if assert_at "${label}.after" assert-clean; then
        passed=$((passed + 1)); ok "cycle ${i} complete and clean"
      fi
    else
      bad "make demo-signalloom-supercred-all failed on cycle ${i} — tail:"
      tail -25 "${RUN_DIR}/${label}.log" >&2 || true
      record_failure "supercred-all cycle ${i} exited non-zero"
    fi
  done
  step "iterate-all: ${passed}/${n} cycles clean"
  [ "$passed" -eq "$n" ]
}

# ─── Mid-run reset ──────────────────────────────────────────────────────────
#
# The case most likely to be broken, and the one a live demo actually hits: the
# presenter aborts partway through and starts over. Reset is invoked DURING
# step 3 — after the compliance scan has begun but before step 4's revocation —
# so the OpenBao credential material seeded by step 1 is still live. Only step 4
# deletes that material, so a teardown here is exactly where the leak shows.
midrun_reset() {
  preflight
  step "mid-run reset — abort during step 3, then recover"

  "$STATE" reset >"${RUN_DIR}/midrun.pre-reset.log" 2>&1 || true

  run_step 1 midrun || return 1
  run_step 2 midrun || return 1
  assert_at "midrun.01-before-abort" assert-step 2 || return 1

  # Start step 3 and interrupt it in flight rather than waiting for it to
  # finish — an abort between the scan starting and the pod being relabelled is
  # a real state the numbered steps have no preflight for.
  log "starting step 3 in the background, then interrupting it mid-flight"
  "$DEMO" 3 >"${RUN_DIR}/midrun.step3.log" 2>&1 &
  local step3_pid=$!
  sleep 3
  if kill -0 "$step3_pid" 2>/dev/null; then
    kill -TERM "$step3_pid" 2>/dev/null || true
    log "step 3 interrupted (pid ${step3_pid})"
  else
    log "step 3 had already completed before the interrupt landed"
  fi
  wait "$step3_pid" 2>/dev/null || true

  # A port-forward orphaned by the interrupt is its own repeatability hazard:
  # it holds :18081 and the next run's forward silently binds nothing.
  local orphans
  orphans="$(pgrep -f 'port-forward svc/policy-engine' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$orphans" != "0" ]; then
    bad "interrupting step 3 orphaned ${orphans} policy-engine port-forward(s) — these squat on :18081 and will silently break the next run"
    record_failure "mid-run abort leaks a port-forward process"
    pkill -f 'port-forward svc/policy-engine' 2>/dev/null || true
  else
    ok "no orphaned port-forward after the abort"
  fi

  step "mid-run reset — tearing down from the aborted state"
  # What the demo offers an operator here is step 5. Measure THAT, not the deep
  # reset, or the leak is hidden by the tool built to work around it.
  if ! "$DEMO" 5 >"${RUN_DIR}/midrun.step5.log" 2>&1; then
    bad "demo step 5 failed from an aborted step-3 state — tail:"
    tail -25 "${RUN_DIR}/midrun.step5.log" >&2 || true
    record_failure "midrun: step 5 exited non-zero from an aborted state"
  fi

  if assert_at "midrun.02-after-step5" assert-clean; then
    ok "mid-run reset leaves genuinely clean state"
  else
    bad "mid-run reset does NOT leave clean state — see the violations above"
  fi

  # Regardless of the verdict above, the demo must be runnable again afterwards.
  # That is the operator's actual question: can I just start over?
  step "mid-run reset — fresh full run from the post-reset state"
  "$STATE" reset >"${RUN_DIR}/midrun.deep-reset.log" 2>&1 || true
  local rc=0
  ITERATIONS=1
  iteration "recovery" || rc=1
  if [ "$rc" -eq 0 ]; then
    ok "a fresh full run succeeds after a mid-run reset"
  else
    record_failure "midrun: a fresh run after reset did not complete cleanly"
  fi
  return "$rc"
}

# ─── Dispatch ───────────────────────────────────────────────────────────────

summarise() {
  step "summary"
  if [ "${#FAILURES[@]}" -eq 0 ]; then
    ok "no failures recorded — evidence in ${RUN_DIR}"
    return 0
  fi
  bad "${#FAILURES[@]} failure(s):"
  local f
  for f in "${FAILURES[@]}"; do printf '  ✗ %s\n' "$f" >&2; done
  printf '\nEvidence: %s\n' "$RUN_DIR" >&2
  return 1
}

case "${1:-}" in
  iterate)      iterate "${2:-$ITERATIONS}" || true; summarise ;;
  iterate-all)  iterate_all "${2:-$ITERATIONS}" || true; summarise ;;
  midrun-reset) midrun_reset || true; summarise ;;
  all)
    iterate "${2:-$ITERATIONS}" || true
    iterate_all "${2:-$ITERATIONS}" || true
    midrun_reset || true
    summarise
    ;;
  *)
    cat >&2 <<'USAGE'
Usage: supercred-e2e.sh <command> [iterations]

  iterate [N]       N full 1→5 cycles; every step's postcondition asserted
  iterate-all [N]   N cycles through `make demo-signalloom-supercred-all`
  midrun-reset      Abort during step 3, tear down, assert clean, run again
  all [N]           All of the above

Default N = 3 (SUPERCRED_E2E_ITERATIONS). Evidence lands in
test-results/supercred-e2e/ as one .state snapshot per assertion point.
USAGE
    exit 1
    ;;
esac
