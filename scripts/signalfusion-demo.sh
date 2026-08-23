#!/usr/bin/env bash
# signalfusion-demo.sh — Signal Fusion three-act demo lifecycle.
#
# Three acts demonstrating signal correlation, blind-spot detection, and
# identity issuance as the resolution to the detection ceiling.
#
#   signalfusion-demo.sh 1     # Act 1: Inferred — deploy, seed, correlate
#   signalfusion-demo.sh 2     # Act 2: Attested — kernel observation
#   signalfusion-demo.sh 3     # Act 3: Issued — promote and close
#   signalfusion-demo.sh all   # Run 1→3 sequentially
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh"

# ─── Configuration ────────────────────────────────────────────────────────────

NAMESPACE_INFRA="${NAMESPACE_INFRA:-inf-signalloom}"
SIGNAL_INGEST_SVC="${SIGNAL_INGEST_SVC:-signal-ingest}"
SIGNAL_INGEST_PORT="${SIGNAL_INGEST_PORT:-8082}"
SIGNAL_INGEST_LOCAL_PORT="${SIGNAL_INGEST_LOCAL_PORT:-18082}"

# ─── Narration ────────────────────────────────────────────────────────────────
# Same timestamp design as supercred-demo.sh: UTC with Z, seconds not ms,
# only on lines this script authored at the moment it printed them.
#
# The `TZ=UTC` prefix is LOAD-BEARING — see supercred-demo.sh for the full
# reasoning. glibc falls back to /etc/localtime when TZ is unset, so on a
# developer's machine the timestamp would print BST, not UTC. Setting it at
# the point of use keeps it off the demo_runner's _ENV_ALLOWLIST too.

log()  { TZ=UTC printf '[%(%H:%M:%SZ)T] \033[1;35m[signalfusion]\033[0m %s\n' -1 "$*"; }
ok()   { TZ=UTC printf '[%(%H:%M:%SZ)T] \033[1;32m[signalfusion] ✓\033[0m %s\n' -1 "$*"; }
fail() { TZ=UTC printf '[%(%H:%M:%SZ)T] \033[1;31m[signalfusion] FAILED:\033[0m %s\n' -1 "$*" >&2; exit 1; }

indent() { sed 's/^/    /'; }

# ─── Port-forward management ─────────────────────────────────────────────────
# Background port-forward to signal-ingest service, cleaned up on exit.
#
# Only needed when the script runs OUTSIDE the cluster — a laptop, `make
# demo-signalfusion`, CI. When it runs as the in-cluster demo runner the
# Service is already reachable by DNS, and SIGNAL_INGEST_URL is set to it.
#
# That override is a privilege decision, not a convenience. `kubectl
# port-forward` requires `create pods/portforward` in the target namespace,
# which lets the holder reach ANY port on ANY pod there — a genuine lateral
# grant, handed to a ServiceAccount so that a demo can talk to a Service it
# can already resolve. Skipping the port-forward is what keeps that verb off
# the runner's Role.

PF_PID=""

start_port_forward() {
  # Already have a direct route to the Service: nothing to forward.
  if [ -n "${SIGNAL_INGEST_URL:-}" ]; then
    return 0
  fi
  if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
    return 0
  fi
  log "port-forwarding svc/${SIGNAL_INGEST_SVC} ${SIGNAL_INGEST_LOCAL_PORT}:${SIGNAL_INGEST_PORT}"
  kubectl -n "$NAMESPACE_INFRA" port-forward "svc/${SIGNAL_INGEST_SVC}" \
    "${SIGNAL_INGEST_LOCAL_PORT}:${SIGNAL_INGEST_PORT}" >/dev/null 2>&1 &
  PF_PID=$!
  wait_reachable "http://localhost:${SIGNAL_INGEST_LOCAL_PORT}/healthz" 30 \
    || fail "signal-ingest port-forward not reachable"
}

stop_port_forward() {
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
    PF_PID=""
  fi
}

trap 'stop_port_forward' EXIT

# ─── API helpers ──────────────────────────────────────────────────────────────

# Defaults to the port-forwarded localhost endpoint, which is what every
# out-of-cluster caller wants. The in-cluster runner sets SIGNAL_INGEST_URL to
# the Service DNS name and start_port_forward then no-ops — see above.
INGEST_URL="${SIGNAL_INGEST_URL:-http://localhost:${SIGNAL_INGEST_LOCAL_PORT}}"

api_post() {
  local path="$1"; shift
  curl -sS --fail -X POST "${INGEST_URL}${path}" \
    -H 'Content-Type: application/json' \
    "$@"
}

api_get() {
  local path="$1"; shift
  curl -sS --fail "${INGEST_URL}${path}" "$@"
}

# ─── Preflight checks ────────────────────────────────────────────────────────

preflight_cluster() {
  log "preflight: checking cluster health"
  kubectl cluster-info >/dev/null 2>&1 || fail "cluster not reachable"
  kubectl get ns "$NAMESPACE_INFRA" >/dev/null 2>&1 \
    || fail "namespace $NAMESPACE_INFRA not found — run make demo-signalloom-up first"
  ok "cluster healthy"
}

preflight_signal_ingest() {
  log "preflight: verifying signal-ingest is deployed"
  # With a direct Service URL, ask the Service rather than the API server.
  #
  # This is not a shortcut around missing RBAC, it is the better question. The
  # rollout check below infers reachability from a Deployment's status; a
  # successful /healthz IS reachability, which is the thing the acts actually
  # depend on. It also needs no read on Deployments — the in-cluster runner has
  # none in this namespace, so the API-server form would fail preflight on a
  # signal-ingest that is up and answering.
  if [ -n "${SIGNAL_INGEST_URL:-}" ]; then
    wait_reachable "${INGEST_URL}/healthz" 60 \
      || fail "signal-ingest not reachable at ${INGEST_URL} — ensure the signal-ingest service is running"
    ok "signal-ingest reachable at ${INGEST_URL}"
    return 0
  fi
  wait_k8s_exists deployment "$SIGNAL_INGEST_SVC" -n "$NAMESPACE_INFRA" 10 \
    || fail "signal-ingest not deployed — ensure the signal-ingest service is running"
  wait_rollout "$SIGNAL_INGEST_SVC" -n "$NAMESPACE_INFRA" 60 \
    || fail "signal-ingest deployment not ready"
  ok "signal-ingest deployed and ready"
}

preflight_act1_completed() {
  log "preflight: verifying Act 1 completed (provisional actor exists)"
  start_port_forward
  local actors
  actors=$(api_get "/api/v1/actors" 2>/dev/null) || fail "cannot reach signal-ingest — run Act 1 first"
  local count
  count=$(printf '%s' "$actors" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d if isinstance(d,list) else d.get('actors',[])))" 2>/dev/null) || count=0
  [ "$count" -gt 0 ] || fail "no provisional actors found — run Act 1 first"
  ok "Act 1 state verified ($count actor(s) present)"
}

preflight_act2_completed() {
  log "preflight: verifying Act 2 completed (kernel observation corroborated)"
  start_port_forward
  local actors
  actors=$(api_get "/api/v1/actors" 2>/dev/null) || fail "cannot reach signal-ingest — run Act 1 first"
  local has_kernel
  has_kernel=$(printf '%s' "$actors" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# /api/v1/actors returns a BARE ARRAY. This used to read d.get('actors', [])
# which raises AttributeError on a list -- swallowed by the 2>/dev/null at
# the call site, so every act after the first reported "run Act 1 first"
# while the actor it wanted was sitting in the response it had just read.
actors = d if isinstance(d, list) else d.get('actors', [])
for a in actors:
    evidence = a.get('evidence_chain', [])
    for e in evidence:
        if e.get('layer') == 'endpoint_host':
            print('yes')
            sys.exit(0)
print('no')
" 2>/dev/null) || has_kernel="no"
  [ "$has_kernel" = "yes" ] || fail "no kernel-layer evidence found — run Act 2 first"
  ok "Act 2 state verified (kernel observation present)"
}

# ─── ACT 1: INFERRED — "The Weave Sees What No Single Thread Can" ─────────

demo_1() {
  preflight_cluster
  preflight_signal_ingest
  log "═══════════════════════════════════════════════════════════════════"
  log "Act 1: INFERRED — The Weave Sees What No Single Thread Can"
  log "═══════════════════════════════════════════════════════════════════"

  start_port_forward

  # Step 1: Verify signal-ingest is healthy
  log "step 1.1: verifying signal-ingest health"
  local health
  health=$(api_get "/healthz") || fail "signal-ingest health check failed"
  ok "signal-ingest healthy"

  # Step 2: Seed fixture observations — 5 layers of data about a shadow agent
  log "step 1.2: seeding fixture observations (5 layers of shadow agent signals)"
  log "  Layers: network_flow, dns_query, process_exec, api_gateway, service_mesh"
  log "  Subject: an unregistered agent communicating with external endpoints"
  local seed_result
  seed_result=$(api_post "/api/v1/collectors/seed") \
    || fail "failed to seed fixture observations"
  log "seed result:"
  printf '%s\n' "$seed_result" | python3 -m json.tool 2>/dev/null | indent || printf '%s\n' "$seed_result" | indent
  ok "fixture observations seeded"

  # Step 3: Run correlation — engine correlates observations across layers
  log "step 1.3: running correlation engine"
  log "  The correlation engine looks for patterns that span multiple observation"
  log "  layers. No single thread tells the story — the weave does."
  local corr_result
  corr_result=$(api_post "/api/v1/correlate") \
    || fail "correlation engine failed"
  log "correlation result:"
  printf '%s\n' "$corr_result" | python3 -m json.tool 2>/dev/null | indent || printf '%s\n' "$corr_result" | indent
  ok "correlation complete"

  # Step 4: Display the provisional actor
  log "step 1.4: displaying provisional actor and evidence chain"
  local actors
  actors=$(api_get "/api/v1/actors") \
    || fail "failed to retrieve actors"
  printf '%s\n' "$actors" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# /api/v1/actors returns a BARE ARRAY. This used to read d.get('actors', [])
# which raises AttributeError on a list -- swallowed by the 2>/dev/null at
# the call site, so every act after the first reported "run Act 1 first"
# while the actor it wanted was sitting in the response it had just read.
actors = d if isinstance(d, list) else d.get('actors', [])
for a in actors:
    print(f\"  Actor: {a.get('id', 'unknown')}\")
    print(f\"  Status: {a.get('status', 'unknown')}\")
    print(f\"  Confidence: {a.get('confidence', 0):.2f}\")
    print(f\"  Evidence chain ({len(a.get('evidence_chain', []))} observations):\")
    for e in a.get('evidence_chain', []):
        fidelity = e.get('fidelity', 'unknown')
        layer = e.get('layer', 'unknown')
        print(f\"    [{fidelity}] {layer}: {e.get('summary', e.get('description', ''))}\")
    print()
" 2>/dev/null || printf '%s\n' "$actors" | python3 -m json.tool 2>/dev/null | indent

  # Step 5: Display coverage panel
  log "step 1.5: displaying coverage panel — what the deployment CAN'T see"
  local coverage
  coverage=$(api_get "/api/v1/coverage" 2>/dev/null) && {
    printf '%s\n' "$coverage" | python3 -c "
import sys, json
d = json.load(sys.stdin)
blind_spots = d.get('blind_spots', [])
if blind_spots:
    print('  Blind spots detected:')
    for b in blind_spots:
        print(f\"    ⚠ {b.get('layer', 'unknown')}: {b.get('description', b.get('reason', ''))}\")
covered = d.get('covered_layers', [])
if covered:
    print(f\"  Covered layers: {', '.join(covered)}\")
" 2>/dev/null || printf '%s\n' "$coverage" | python3 -m json.tool 2>/dev/null | indent
  } || log "  (coverage endpoint not yet implemented — blind spots will be inferred from evidence gaps)"

  # Evidence artefact: capture the full actor JSON
  log "────────────────────────────────────────────────────────"
  log "EVIDENCE ARTEFACT: provisional actor with evidence chain"
  printf '%s\n' "$actors" | python3 -m json.tool 2>/dev/null | indent || printf '%s\n' "$actors" | indent
  log "────────────────────────────────────────────────────────"

  ok "Act 1 complete — provisional actor inferred from correlated signals"
}

# ─── ACT 2: ATTESTED — "The Kernel Sees What The Network Cannot" ──────────

demo_2() {
  preflight_act1_completed
  log "═══════════════════════════════════════════════════════════════════"
  log "Act 2: ATTESTED — The Kernel Sees What The Network Cannot"
  log "═══════════════════════════════════════════════════════════════════"

  start_port_forward

  # Step 1: Show the local-transport blind spot
  log "step 2.1: identifying the local-transport blind spot"
  log "  An agent communicating via Unix socket (AF_UNIX) is invisible to"
  log "  network-layer collectors. The CNI sees nothing. The service mesh"
  log "  sees nothing. Only the kernel knows."

  # Capture pre-observation confidence
  local actors_before
  actors_before=$(api_get "/api/v1/actors") \
    || fail "failed to retrieve actors"
  local confidence_before
  confidence_before=$(printf '%s' "$actors_before" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# /api/v1/actors returns a BARE ARRAY. This used to read d.get('actors', [])
# which raises AttributeError on a list -- swallowed by the 2>/dev/null at
# the call site, so every act after the first reported "run Act 1 first"
# while the actor it wanted was sitting in the response it had just read.
actors = d if isinstance(d, list) else d.get('actors', [])
if actors:
    print(f\"{actors[0].get('confidence', 0):.2f}\")
else:
    print('0.00')
" 2>/dev/null) || confidence_before="0.00"
  log "  current confidence: $confidence_before"

  # Step 2: Simulate kernel observation (eBPF endpoint_host layer)
  log "step 2.2: injecting kernel-layer observation (simulated eBPF)"
  log "  Observation: Unix socket communication detected between shadow agent"
  log "  and local model inference server. Fidelity: definitive."

  # Get the actor ID for the kernel observation
  local actor_id
  actor_id=$(printf '%s' "$actors_before" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# /api/v1/actors returns a BARE ARRAY. This used to read d.get('actors', [])
# which raises AttributeError on a list -- swallowed by the 2>/dev/null at
# the call site, so every act after the first reported "run Act 1 first"
# while the actor it wanted was sitting in the response it had just read.
actors = d if isinstance(d, list) else d.get('actors', [])
if actors:
    print(actors[0].get('id', ''))
" 2>/dev/null) || actor_id=""

  # The actor_hint, not the actor id. Correlation matches observations whose
  # actor_hint is EQUAL (rules.go: `a.actor_hint == b.actor_hint`), and the
  # engine derives the id as "actor-" + hint (engine.go:168). Posting the id
  # here would store an observation that correlates with nothing, so Act 2
  # would "succeed" and Act 3 would still find no kernel evidence.
  local actor_hint
  actor_hint="${actor_id#actor-}"

  local kernel_observation
  # POST /api/v1/observations takes an ARRAY of model.Observation, and every
  # field below is required by Observation.Validate(): id, timestamp, layer,
  # fidelity, source, confidence, raw_evidence_ref, description. Labels are
  # map[string]string, so the nested process and syscall detail this demo
  # narrates is flattened into strings -- a nested value fails the decode
  # before Validate ever runs.
  #
  # This used to POST a differently-shaped body to a collectors/observe path
  # that has never existed: the service registers exactly eleven routes
  # (handlers.go:54-64) and that is not among them. It 404s, so Act 2 could
  # never complete and Act 3 could never start.
  kernel_observation=$(cat <<EOF
[
  {
    "id": "kernel-ebpf-$(TZ=UTC printf '%(%Y%m%d%H%M%S)T' -1)",
    "timestamp": "$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)",
    "layer": "endpoint_host",
    "fidelity": "definitive",
    "source": "ebpf-kernel-collector",
    "confidence": 0.95,
    "actor_hint": "${actor_hint}",
    "raw_evidence_ref": "ebpf://kernel/unix_socket/4821",
    "labels": {
      "type": "unix_socket_communication",
      "socket_path": "/var/run/shadow-agent/inference.sock",
      "process": "shadow-agent",
      "pid": "4821",
      "peer_process": "ollama-server",
      "peer_pid": "4900",
      "uid": "0",
      "bytes_transferred": "2457600",
      "syscalls": "connect,sendmsg,recvmsg"
    },
    "description": "Unix socket communication: shadow-agent (PID 4821) to ollama-server via /var/run/shadow-agent/inference.sock — 2.3MB transferred, invisible at network layer"
  }
]
EOF
)

  local inject_result
  inject_result=$(api_post "/api/v1/observations" -d "$kernel_observation") \
    || fail "failed to inject kernel observation"
  log "kernel observation injected:"
  printf '%s\n' "$inject_result" | python3 -m json.tool 2>/dev/null | indent || printf '%s\n' "$inject_result" | indent
  ok "kernel observation recorded"

  # Step 3: Re-run correlation
  log "step 2.3: re-running correlation with kernel evidence"
  local corr_result
  corr_result=$(api_post "/api/v1/correlate") \
    || fail "correlation engine failed"
  log "correlation result:"
  printf '%s\n' "$corr_result" | python3 -m json.tool 2>/dev/null | indent || printf '%s\n' "$corr_result" | indent
  ok "correlation updated"

  # Step 4: Show the updated actor — confidence should have jumped
  log "step 2.4: displaying updated actor with kernel corroboration"
  local actors_after
  actors_after=$(api_get "/api/v1/actors") \
    || fail "failed to retrieve updated actors"
  local confidence_after
  confidence_after=$(printf '%s' "$actors_after" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# /api/v1/actors returns a BARE ARRAY. This used to read d.get('actors', [])
# which raises AttributeError on a list -- swallowed by the 2>/dev/null at
# the call site, so every act after the first reported "run Act 1 first"
# while the actor it wanted was sitting in the response it had just read.
actors = d if isinstance(d, list) else d.get('actors', [])
if actors:
    print(f\"{actors[0].get('confidence', 0):.2f}\")
else:
    print('0.00')
" 2>/dev/null) || confidence_after="0.00"

  printf '%s\n' "$actors_after" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# /api/v1/actors returns a BARE ARRAY. This used to read d.get('actors', [])
# which raises AttributeError on a list -- swallowed by the 2>/dev/null at
# the call site, so every act after the first reported "run Act 1 first"
# while the actor it wanted was sitting in the response it had just read.
actors = d if isinstance(d, list) else d.get('actors', [])
for a in actors:
    print(f\"  Actor: {a.get('id', 'unknown')}\")
    print(f\"  Status: {a.get('status', 'unknown')}\")
    print(f\"  Confidence: {a.get('confidence', 0):.2f}\")
    chain = a.get('evidence_chain', [])
    print(f\"  Evidence chain ({len(chain)} observations):\")
    for e in chain:
        fidelity = e.get('fidelity', 'unknown')
        layer = e.get('layer', 'unknown')
        marker = ' ← NEW (kernel)' if layer == 'endpoint_host' else ''
        print(f\"    [{fidelity}] {layer}: {e.get('summary', e.get('description', ''))}{marker}\")
    print()
" 2>/dev/null || printf '%s\n' "$actors_after" | python3 -m json.tool 2>/dev/null | indent

  # Evidence artefact: before/after confidence comparison
  log "────────────────────────────────────────────────────────"
  log "EVIDENCE ARTEFACT: confidence before/after kernel attestation"
  log "  Before: $confidence_before"
  log "  After:  $confidence_after"
  log "  The kernel sees what the network cannot."
  log "────────────────────────────────────────────────────────"

  ok "Act 2 complete — kernel attestation corroborated the provisional actor"
}

# ─── ACT 3: ISSUED — "Detection Solved By Identity" ──────────────────────

demo_3() {
  preflight_act2_completed
  log "═══════════════════════════════════════════════════════════════════"
  log "Act 3: ISSUED — Detection Solved By Identity"
  log "═══════════════════════════════════════════════════════════════════"

  start_port_forward

  # Get the actor to promote
  local actors
  actors=$(api_get "/api/v1/actors") \
    || fail "failed to retrieve actors"
  local actor_id
  actor_id=$(printf '%s' "$actors" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# /api/v1/actors returns a BARE ARRAY. This used to read d.get('actors', [])
# which raises AttributeError on a list -- swallowed by the 2>/dev/null at
# the call site, so every act after the first reported "run Act 1 first"
# while the actor it wanted was sitting in the response it had just read.
actors = d if isinstance(d, list) else d.get('actors', [])
if actors:
    print(actors[0].get('id', ''))
" 2>/dev/null) || actor_id=""
  [ -n "$actor_id" ] || fail "no actor found to promote"
  log "actor to promote: $actor_id"

  # Step 1: Promote the actor
  log "step 3.1: promoting provisional actor to governed agent"
  log "  The detection problem becomes an identity problem. Once promoted,"
  log "  the shadow agent enters the governance plane — observable, auditable,"
  log "  and revocable via the existing SuperCred machinery."
  local promote_result
  promote_result=$(api_post "/api/v1/actors/${actor_id}/promote") \
    || fail "actor promotion failed"
  log "promotion result:"
  printf '%s\n' "$promote_result" | python3 -m json.tool 2>/dev/null | indent || printf '%s\n' "$promote_result" | indent
  ok "actor promoted to governed agent"

  # Step 2: Show the agent in the registry
  log "step 3.2: verifying agent appears in the governance registry"
  local registry
  registry=$(api_get "/api/v1/agents" 2>/dev/null) && {
    printf '%s\n' "$registry" | python3 -c "
import sys, json
d = json.load(sys.stdin)
agents = d.get('agents', d.get('items', []))
for a in agents:
    status = a.get('status', 'unknown')
    name = a.get('name', a.get('id', 'unknown'))
    origin = a.get('origin', '')
    marker = ' ← PROMOTED from Signal Fusion' if origin == 'signal-fusion' or 'promoted' in status.lower() else ''
    print(f\"  {name}: {status}{marker}\")
" 2>/dev/null || printf '%s\n' "$registry" | python3 -m json.tool 2>/dev/null | indent
  } || log "  (agent registry endpoint not yet implemented — the promoted agent will appear on the Agents page)"

  # Step 3: Show coverage panel update
  log "step 3.3: displaying updated coverage — blind spots closeable by issuance"
  local coverage
  coverage=$(api_get "/api/v1/coverage" 2>/dev/null) && {
    printf '%s\n' "$coverage" | python3 -c "
import sys, json
d = json.load(sys.stdin)
blind_spots = d.get('blind_spots', [])
closeable = [b for b in blind_spots if b.get('closeable_by') == 'issuance']
remaining = [b for b in blind_spots if b.get('closeable_by') != 'issuance']
if closeable:
    print('  Blind spots now closeable by identity issuance:')
    for b in closeable:
        print(f\"    ✓ {b.get('layer', 'unknown')}: {b.get('description', '')} — closeable via credential issuance\")
if remaining:
    print('  Remaining blind spots:')
    for b in remaining:
        print(f\"    ⚠ {b.get('layer', 'unknown')}: {b.get('description', '')}\")
" 2>/dev/null || printf '%s\n' "$coverage" | python3 -m json.tool 2>/dev/null | indent
  } || {
    log "  session_inheritance: closeable by issuance — agent now has a credential chain"
    log "  local_transport: closeable by issuance — kernel attestation proves the communication path"
  }

  # Evidence artefact: full chain from first observation to promoted agent
  log "────────────────────────────────────────────────────────"
  log "EVIDENCE ARTEFACT: complete signal fusion chain"
  log "  1. Network/DNS/process/API/mesh observations seeded"
  log "  2. Correlation engine inferred a provisional actor"
  log "  3. Kernel attestation (eBPF) corroborated the finding"
  log "  4. Actor promoted to governed agent with identity"
  log "  5. Detection ceiling resolved by identity issuance"
  log ""
  log "  The full chain:"
  local final_actor
  final_actor=$(api_get "/api/v1/actors/${actor_id}" 2>/dev/null) && {
    printf '%s\n' "$final_actor" | python3 -m json.tool 2>/dev/null | indent || printf '%s\n' "$final_actor" | indent
  } || {
    printf '%s\n' "$promote_result" | python3 -m json.tool 2>/dev/null | indent || printf '%s\n' "$promote_result" | indent
  }
  log "────────────────────────────────────────────────────────"

  ok "Act 3 complete — shadow agent discovered, attested, and issued identity"
  log ""
  log "The detection ceiling is a problem of identity, not of coverage."
  log "Signal Fusion proves the agent exists. SuperCred gives it a credential."
  log "What was invisible is now governable."
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────

run_all() {
  log "running full Signal Fusion demo (Acts 1→3)"
  demo_1
  demo_2
  demo_3
  ok "full Signal Fusion demo complete"
}

case "${1:-}" in
  1) demo_1 ;;
  2) demo_2 ;;
  3) demo_3 ;;
  all) run_all ;;
  *)
    echo "Usage: $0 {1|2|3|all}" >&2
    echo ""
    echo "  1    Act 1: Inferred — deploy signal collectors, seed, correlate"
    echo "  2    Act 2: Attested — kernel observation covers the blind spot"
    echo "  3    Act 3: Issued — promote actor, close with identity"
    echo "  all  Run 1→3 sequentially"
    exit 1
    ;;
esac
