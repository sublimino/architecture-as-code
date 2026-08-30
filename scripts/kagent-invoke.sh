#!/usr/bin/env bash
# scripts/kagent-invoke.sh — Trigger one kagent agent and watch it work.
#
# @id      kagent-invoke
# @doc     docs/kagent-d5.md
# @tests   d2-signalloom/test/kagent-invoke.bats
#
# WHAT THIS ADDS
#
# Before this, nothing in the repo could invoke an agent. `make demo-kagent-demo`
# is a sequence of `kubectl get`; scripts/kagent-harness-exec.sh writes a proof
# file and runs tests. Both report on agents that have never executed a single
# turn. Eight Agent CRs existed and none had ever run.
#
# THE MECHANISM IS UPSTREAM'S
#
# Every kagent agent implements the A2A protocol, and the controller serves it:
#
#   GET  /api/a2a/{namespace}/{agent}/.well-known/agent.json   -> the agent card
#   POST /api/a2a/{namespace}/{agent}/                         -> JSON-RPC
#
# on port 8083 of svc/kagent-controller. That is the same surface the kagent
# CLI (`kagent invoke --agent X --task Y`), the dashboard, and the A2A host CLI
# all use. Nothing bespoke is invented here; this is a thin, dependency-free
# client for a documented protocol, so it works without installing the kagent
# CLI on the operator's machine.
#
# WHY THE RESPONSE HANDLING IS FUSSY
#
# Four distinct shapes mean failure, and three of them arrive as HTTP 200:
#   - a JSON-RPC `error` object
#   - `result.status.state == "failed"` with no error object
#   - a proxy or gateway HTML page served with a 200
#   - a completed task carrying no text at all
# Checking only the HTTP code, or only `.error`, reports the other three as
# success. An invocation path that cannot distinguish "the agent answered" from
# "something answered" is worse than no invocation path, because it manufactures
# evidence.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=scripts/lib/env-file.sh
. "${REPO_ROOT}/scripts/lib/env-file.sh"

KUBECTL="${KUBECTL:-kubectl}"
CURL="${CURL:-curl}"
SECRET_NAME="${KAGENT_SECRET_NAME:-kagent-anthropic-key}"
SECRET_KEY="${KAGENT_SECRET_KEY:-ANTHROPIC_API_KEY}"

AGENTS_NS="${KAGENT_AGENTS_NAMESPACE:-fe-signalloom-agents}"
CONTROL_NS="${KAGENT_CONTROL_NAMESPACE:-kagent}"
CONTROLLER_SVC="${KAGENT_CONTROLLER_SERVICE:-kagent-controller}"
CONTROLLER_PORT="${KAGENT_CONTROLLER_PORT:-8083}"
UI_SVC="${KAGENT_UI_SERVICE:-kagent-ui}"
UI_PORT="${KAGENT_UI_PORT:-8080}"
TIMEOUT="${KAGENT_INVOKE_TIMEOUT:-180}"

AGENT=""
PROMPT=""
PF_PID=""

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: ${0##*/} --agent <name> --prompt <text> [--namespace <ns>] [--timeout <s>]

Invokes one kagent agent through the controller's A2A endpoint, prints the
agent's actual response, and exits non-zero if the agent errors.

  --agent      Agent CR name, e.g. kagent-k8s-reader   (required)
  --prompt     The task to send the agent                (required)
  --namespace  Namespace holding the Agent CR (default: ${AGENTS_NS})
  --timeout    Seconds to wait for the response (default: ${TIMEOUT})
  --help       This text

Example:
  ${0##*/} --agent kagent-k8s-reader \\
           --prompt "List every namespace in the cluster and count them."

Environment:
  KAGENT_A2A_BASE   Skip the port-forward and use this base URL directly,
                    e.g. http://127.0.0.1:${CONTROLLER_PORT}
  KUBECTL, CURL     Binary overrides (used by the test suite)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)     AGENT="${2:-}"; shift 2 ;;
    --prompt)    PROMPT="${2:-}"; shift 2 ;;
    --namespace) AGENTS_NS="${2:-}"; shift 2 ;;
    --timeout)   TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           printf 'ERROR: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

[ -n "$AGENT" ]  || { printf 'ERROR: --agent is required\n\n' >&2; usage >&2; exit 1; }
[ -n "$PROMPT" ] || { printf 'ERROR: --prompt is required\n\n' >&2; usage >&2; exit 1; }

# ─── Preconditions ────────────────────────────────────────────────────────────
#
# Checked here so a typo fails as "that agent does not exist" rather than as a
# 404 from a URL the operator has to decode themselves.

if ! "$KUBECTL" get agent "$AGENT" -n "$AGENTS_NS" >/dev/null 2>&1; then
  fail "no Agent CR named '${AGENT}' in namespace '${AGENTS_NS}'.

  Deployed agents:
$("$KUBECTL" get agents -n "$AGENTS_NS" -o name 2>/dev/null | sed 's|^|    |' || echo '    (none — run: make demo-kagent-up)')"
fi

# ─── The model credential must exist. This is where we fail LOUDLY ────────────
#
# The credential-seeding target deliberately no-ops when no key is configured,
# matching this repo's precedent for optional credentials (olly-llm-secret.sh):
# a missing optional key must not break `make up`.
#
# Here it is not optional. Invoking an agent with no model credential produces a
# provider authentication error several layers down, surfacing as an opaque
# JSON-RPC failure that reads like a broken agent. Checking first turns that
# into one sentence naming the file and the command that fixes it.
#
# Skippable for the unit tests, which have no cluster and are not testing this.
if [ "${KAGENT_SKIP_CREDENTIAL_CHECK:-0}" != "1" ]; then
  if ! "$KUBECTL" get secret "$SECRET_NAME" -n "$AGENTS_NS" \
        -o "jsonpath={.data.${SECRET_KEY}}" 2>/dev/null | grep -q .; then
    signalloom_load_env
    fail "no model credential: Secret/${SECRET_NAME} (key ${SECRET_KEY}) is absent or
  empty in namespace '${AGENTS_NS}'. ${AGENT} cannot complete a model call.

  Fix it:
      1. put ANTHROPIC_API_KEY=sk-ant-... in ${SIGNALLOOM_ENV_FILE_RESOLVED:-<repo>/.env}
      2. make demo-kagent-credentials

  .env is gitignored — the key is never committed.
  ANTHROPIC_API_KEY currently resolves from: $(signalloom_env_provenance ANTHROPIC_API_KEY)"
  fi
fi

# ─── Transport ────────────────────────────────────────────────────────────────

cleanup() {
  if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  [ -n "${WORKDIR:-}" ] && rm -rf "$WORKDIR"
  return 0
}
trap cleanup EXIT INT TERM

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/kagent-invoke.XXXXXX")"

BASE="${KAGENT_A2A_BASE:-}"
if [ -z "$BASE" ]; then
  # Port 0 lets the kernel pick, so concurrent invocations do not collide on a
  # fixed local port — this script is expected to be run ad hoc, possibly twice.
  LOCAL_PORT="${KAGENT_LOCAL_PORT:-18083}"
  log "==> Port-forwarding svc/${CONTROLLER_SVC} ${LOCAL_PORT}:${CONTROLLER_PORT} (namespace ${CONTROL_NS})"
  "$KUBECTL" port-forward -n "$CONTROL_NS" "svc/${CONTROLLER_SVC}" \
    "${LOCAL_PORT}:${CONTROLLER_PORT}" >"${WORKDIR}/pf.log" 2>&1 &
  PF_PID=$!
  BASE="http://127.0.0.1:${LOCAL_PORT}"

  # Poll for readiness rather than sleeping: a fixed sleep is either too short
  # (flaky) or wasted time, and it hides the failure when the forward dies.
  ready=0
  for _ in $(seq 1 40); do
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      fail "port-forward exited immediately:
$(sed 's|^|    |' "${WORKDIR}/pf.log")"
    fi
    if "$CURL" -sS -o /dev/null -m 2 "${BASE}/" 2>/dev/null; then ready=1; break; fi
    sleep 0.25
  done
  [ "$ready" = "1" ] || fail "port-forward to svc/${CONTROLLER_SVC} never became ready
$(sed 's|^|    |' "${WORKDIR}/pf.log" 2>/dev/null || true)"
fi

AGENT_URL="${BASE}/api/a2a/${AGENTS_NS}/${AGENT}/"
CARD_URL="${AGENT_URL}.well-known/agent.json"

# ─── 1. Agent card ────────────────────────────────────────────────────────────
#
# Fetched before invoking, not for decoration: if the controller is not serving
# a card for this agent, the agent is not reconciled and the POST would fail in
# a way that reads like a model error.

CARD_BODY="${WORKDIR}/card.json"
log "==> Fetching agent card"
log "    ${CARD_URL}"
card_code="$("$CURL" -sS -m 15 -o "$CARD_BODY" -w '%{http_code}' "$CARD_URL" 2>/dev/null || true)"

if [ "$card_code" != "200" ]; then
  fail "agent card not served: HTTP ${card_code:-000} from ${CARD_URL}

  The Agent CR exists but the controller is not exposing it over A2A. Either
  the controller has not reconciled it, or the control plane does not implement
  the A2A surface. Check:
    ${KUBECTL} -n ${CONTROL_NS} logs deploy/${CONTROLLER_SVC} --tail=50
    ${KUBECTL} -n ${AGENTS_NS} get agent ${AGENT} -o yaml"
fi

if command -v jq >/dev/null 2>&1 && jq -e . "$CARD_BODY" >/dev/null 2>&1; then
  log "    agent: $(jq -r '.name // "?"' "$CARD_BODY")   streaming: $(jq -r '.capabilities.streaming // "?"' "$CARD_BODY")"
fi

# ─── 2. Invoke ────────────────────────────────────────────────────────────────
#
# The prompt is written to a file and handed to curl by path. It never enters
# argv: /proc/<pid>/cmdline is world-readable, argv lands in shell history, and
# a single argv element is capped at 131,072 bytes by the kernel regardless.

REQ="${WORKDIR}/request.json"
RESP="${WORKDIR}/response.json"
MSG_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)"

if command -v jq >/dev/null 2>&1; then
  # jq does the JSON escaping, so a prompt containing quotes, newlines or
  # backslashes produces a valid body instead of a silent parse error upstream.
  jq -n --arg id "$MSG_ID" --arg text "$PROMPT" '{
    jsonrpc: "2.0",
    id: $id,
    method: "message/send",
    params: { message: { role: "user", messageId: $id, kind: "message",
                         parts: [ { kind: "text", text: $text } ] } }
  }' >"$REQ"
else
  fail "jq is required to build the A2A request body safely"
fi

log ""
log "==> Invoking ${AGENT}"
log "    POST ${AGENT_URL}"
log "    prompt: ${PROMPT}"
log ""

resp_code="$("$CURL" -sS -m "$TIMEOUT" -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  --data-binary "@${REQ}" \
  -o "$RESP" -w '%{http_code}' "$AGENT_URL" 2>/dev/null || true)"

watch_hint() {
  log ""
  log "--- watch it in the UI ---"
  log "  ${KUBECTL} -n ${CONTROL_NS} port-forward svc/${UI_SVC} ${UI_PORT}:${UI_PORT}"
  log "  then open http://localhost:${UI_PORT}  and select '${AGENT}'"
  log "  controller logs: ${KUBECTL} -n ${CONTROL_NS} logs deploy/${CONTROLLER_SVC} -f"
}

if [ "$resp_code" != "200" ]; then
  log "$(head -c 2000 "$RESP" 2>/dev/null || true)"
  watch_hint
  fail "agent endpoint returned HTTP ${resp_code:-000}"
fi

# ─── 3. Interpret ─────────────────────────────────────────────────────────────

if ! jq -e . "$RESP" >/dev/null 2>&1; then
  log "$(head -c 2000 "$RESP" 2>/dev/null || true)"
  watch_hint
  fail "agent returned HTTP 200 with a body that is not JSON. A gateway or proxy
  error page served as 200 is the shape that reads as success — it is not one."
fi

rpc_error="$(jq -r '.error.message // empty' "$RESP")"
if [ -n "$rpc_error" ]; then
  log "Agent returned a JSON-RPC error:"
  log "  code   : $(jq -r '.error.code // "?"' "$RESP")"
  log "  message: ${rpc_error}"
  watch_hint
  exit 1
fi

state="$(jq -r '.result.status.state // empty' "$RESP")"

# Both response shapes appear in upstream's own documented output: text can live
# in result.artifacts[].parts[] or in result.status.message.parts[]. Handling
# only one produces a silent empty success on the other.
text="$(jq -r '
  [ (.result.artifacts // [])[]?.parts[]? | select(.kind == "text" or .type == "text") | .text ]
  + [ (.result.status.message.parts // [])[]? | select(.kind == "text" or .type == "text") | .text ]
  | map(select(. != null and . != "")) | unique_by(.) | join("\n")
' "$RESP")"

if [ "$state" = "failed" ] || [ "$state" = "canceled" ] || [ "$state" = "rejected" ]; then
  log "Agent task state: ${state}"
  [ -n "$text" ] && log "${text}"
  watch_hint
  fail "agent task ${state}"
fi

if [ -z "$text" ]; then
  log "Raw response:"
  log "$(head -c 2000 "$RESP")"
  watch_hint
  fail "agent returned a well-formed response carrying no text. An empty
  completed task is indistinguishable from a working agent with nothing to say,
  and is the shape a half-wired controller produces — so it is treated as a
  failure, not as success."
fi

log "--- ${AGENT} responded (state: ${state:-unknown}) ---"
log ""
log "${text}"
watch_hint
exit 0
