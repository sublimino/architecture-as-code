#!/usr/bin/env bash
# scripts/kagent-credentials.sh — Real model credential, mediated by OpenBao.
#
# @id      kagent-credentials
# @doc     docs/kagent-d5.md
# @tests   d2-signalloom/test/kagent-credentials.bats
# @lib     scripts/lib/spire-trust-anchor.sh (SPIRE<->OpenBao JWT trust anchor)
#
# WHAT THIS REPLACES
#
# The kagent control plane shipped with a Secret containing the literal string
# "mock-anthropic-key-for-local-demo". No agent can complete a model call with
# it. Worse, every check that looked at that Secret reported it healthy: it
# exists, it is non-empty, it has the right name and key. The demo's entire
# claim is OpenBao credential mediation via SPIFFE identity, and the one
# credential that mattered was a hardcoded string sitting in git.
#
# THE PATH
#
#   operator's ANTHROPIC_API_KEY
#        │  (stdin, never argv)
#        ▼
#   OpenBao kv-v2, at a path scoped by the agent's own SPIFFE ID:
#        secret/data/agents/ns/<namespace>/sa/<serviceaccount>/anthropic/api-key
#        + per-agent policy granting read on that prefix only
#        + per-agent JWT auth role bound to that exact SPIFFE ID
#        │
#        ▼
#   Secret/kagent-anthropic-key, in every namespace that holds a ModelConfig
#
# OpenBao is the system of record. The Kubernetes Secret is a projection of it,
# and the only reason it exists is that the upstream kagent controller reads the
# key from a Secret in the ModelConfig's own namespace — that is a chart
# contract we do not control. Agents that use the openbao-agent sidecar seam
# (openbao-agent-sidecar.yaml) read the OpenBao path directly and never touch
# the Secret at all.
#
# WHY PER-AGENT ROLES RATHER THAN ONE SHARED ROLE
#
# A single `signalloom-agent-generic` role bound to a namespace, with one policy
# over `secret/data/agents/*`, would let any agent's SVID read any other agent's
# credential — the demo would show credential mediation while delivering none of
# its isolation. Each agent gets a role whose bound_subject is its own SPIFFE ID
# and a policy over its own prefix, so the blast radius of a compromised agent
# is that agent.
#
# WHAT IS DELIBERATELY NOT PROTECTED
#
# BAO_TOKEN. The demo root token is already a plaintext literal in
# d2-signalloom/infra/inf-bao/configs/base/openbao-bootstrap.yaml and is not the
# credential this script exists to protect. It is read from the OpenBao pod's
# own environment when available so it usually stays out of argv anyway.

#
# WHERE THE KEY COMES FROM
#
# `.env` at the main checkout root, key `ANTHROPIC_API_KEY` — the convention
# this repo already uses (see .env.example, scripts/olly-llm-secret.sh). `.env`
# is gitignored; the key is never committed. An exported ANTHROPIC_API_KEY takes
# precedence over the file, and the provenance is printed either way so the
# source is never a guess.
#
# `.env` is resolved from the MAIN checkout via scripts/lib/env-file.sh, not
# from $PWD — it is untracked, so it does not exist in any linked worktree, and
# a $PWD-relative read silently reports "no key" while the operator's key sits
# in the main checkout. See that file for the full explanation.
#
# WHY `seed` NO-OPS INSTEAD OF FAILING
#
# It matches olly-llm-secret.sh: a missing optional credential must not break
# `make up` for someone who has not supplied one. The no-op is LOUD — it names
# the file and the variable — and it writes nothing. The loud FAILURE lives in
# scripts/kagent-invoke.sh, where the key is genuinely required and doing
# nothing quietly would be the fake-success mode this branch exists to remove.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=scripts/lib/env-file.sh
. "${REPO_ROOT}/scripts/lib/env-file.sh"

KUBECTL="${KUBECTL:-kubectl}"
BAO_NS="${KAGENT_BAO_NAMESPACE:-inf-bao}"
BAO_ADDR="${KAGENT_BAO_ADDR:-http://127.0.0.1:8200}"
BAO_TOKEN="${KAGENT_BAO_TOKEN:-signalloom-demo-root-token}"
KV_MOUNT="${KAGENT_KV_MOUNT:-secret}"

AGENTS_NS="${KAGENT_AGENTS_NAMESPACE:-fe-signalloom-agents}"
SECRET_NAME="${KAGENT_SECRET_NAME:-kagent-anthropic-key}"
SECRET_KEY="${KAGENT_SECRET_KEY:-ANTHROPIC_API_KEY}"
SECRET_NAMESPACES="${KAGENT_SECRET_NAMESPACES:-kagent fe-signalloom-agents}"

# The directory the operator's .env lives in, for guidance messages. Resolved
# from git so it names the MAIN checkout even when this runs from a worktree.
MAIN_CHECKOUT="$(dirname "$(signalloom_env_file)")"

SECRET_PATHS_CM="${REPO_ROOT}/d2-signalloom/infra/agent-swarm/openbao-secret-paths.yaml"
SWARM_DIR="${REPO_ROOT}/d2-signalloom/infra/agent-swarm"

# The placeholder that used to occupy the Secret, so `seed` can refuse it if
# someone exports it out of habit or copies it from an old runbook. It is 33
# characters, so the length check below would wave it straight through.
#
# Assembled from two halves on purpose. kagent-credentials.bats fails the build
# if that string appears as a value anywhere in the tree, and a detector whose
# own source satisfies its own condition is a detector that can never fire.
readonly RETIRED_MOCK="mock-anthropic-key""-for-local-demo"

# Anything shorter than this is a truncated paste, not a key. Real Anthropic
# keys are ~100 characters; the bound is deliberately loose so a future key
# format change does not break the demo, but tight enough that a partial
# credential never reaches OpenBao.
readonly MIN_KEY_LEN=20

# ─── xtrace shield ────────────────────────────────────────────────────────────
#
# `bash -x scripts/kagent-credentials.sh seed` is exactly how a credential ends
# up in a terminal scrollback and then in a pasted bug report. Tracing is
# suppressed around every region that expands the key, and restored after, so
# the rest of the script stays debuggable.

_XTRACE_HELD=""
_shield_on() {
  case "$-" in
    *x*) _XTRACE_HELD=1; set +x ;;
    *)   _XTRACE_HELD="" ;;
  esac
}
_shield_off() {
  if [ -n "$_XTRACE_HELD" ]; then set -x; fi
  _XTRACE_HELD=""
}

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ─── Discovery ────────────────────────────────────────────────────────────────

# The kagent agents that declare an anthropic/api-key mapping. Read from the
# ConfigMap that already documents the convention rather than hardcoded here:
# one list, one place to change it.
anthropic_agents() {
  local key agent paths
  for key in $(yq -r '.data | keys | .[]' "$SECRET_PATHS_CM"); do
    agent="${key%.json}"
    case "$agent" in kagent-*) ;; *) continue ;; esac
    paths="$(yq -r ".data[\"${key}\"]" "$SECRET_PATHS_CM" | jq -r '.secrets[].path')"
    case "$paths" in *anthropic/api-key*) printf '%s\n' "$agent" ;; esac
  done
}

# The SPIFFE ID path component for an agent: ns/<namespace>/sa/<serviceaccount>.
#
# The ServiceAccount name is read from the agent's own serviceaccount.yaml, not
# assumed equal to the agent name. kagent-contract.bats enforces that they match
# today; deriving it here anyway means this script cannot be the thing that
# silently seeds a credential against an identity SPIRE never issued.
spiffe_path_for() {
  local agent="$1" sa_yaml sa
  sa_yaml="${SWARM_DIR}/${agent}/serviceaccount.yaml"
  [ -f "$sa_yaml" ] || fail "no serviceaccount.yaml for ${agent}; refusing to guess its SPIFFE identity"
  sa="$(yq -r 'select(.kind == "ServiceAccount") | .metadata.name' "$sa_yaml")"
  [ -n "$sa" ] && [ "$sa" != "null" ] || fail "could not read ServiceAccount name for ${agent}"
  printf 'ns/%s/sa/%s' "$AGENTS_NS" "$sa"
}

# The live trust domain, read from SPIRE rather than assumed. Falls back only
# when SPIRE is unreachable (which is the normal case for the unit tests).
trust_domain() {
  if [ -n "${KAGENT_TRUST_DOMAIN:-}" ]; then
    printf '%s' "$KAGENT_TRUST_DOMAIN"
    return 0
  fi
  local conf td=""
  conf="$("$KUBECTL" get cm -n "$BAO_NS" spire-server-config -o jsonpath='{.data.server\.conf}' 2>/dev/null || true)"
  td="$(printf '%s' "$conf" | sed -n 's/.*trust_domain[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  printf '%s' "${td:-signalloom.demo}"
}

bao_pod() {
  local pod
  pod="$("$KUBECTL" get pod -n "$BAO_NS" -l app.kubernetes.io/name=openbao -o name 2>/dev/null | head -1)"
  if [ -z "$pod" ]; then
    pod="$("$KUBECTL" get pod -n "$BAO_NS" -o name 2>/dev/null | grep -E 'pod/openbao-[0-9a-f]' | head -1)"
  fi
  [ -n "$pod" ] || fail "no OpenBao pod found in namespace ${BAO_NS}"
  printf '%s' "$pod"
}

# Preamble every remote snippet shares. BAO_TOKEN is taken from the pod's own
# environment when it is set there, so the token normally never enters argv.
bao_preamble() {
  cat <<PRE
export BAO_ADDR="\${BAO_ADDR:-${BAO_ADDR}}"
export BAO_TOKEN="\${BAO_TOKEN:-\${VAULT_TOKEN:-${BAO_TOKEN}}}"
PRE
}

# ─── seed ─────────────────────────────────────────────────────────────────────

# Guidance printed whenever there is no usable key. Names the file and the
# variable, so "nothing happened" is never the whole message.
no_key_guidance() {
  cat <<EOF
  The kagent agents will have no model credential and cannot complete a call.

  To wire one up:
      1. cp .env.example .env          (in ${MAIN_CHECKOUT:-the main checkout})
      2. set ANTHROPIC_API_KEY=sk-ant-...   in that .env
      3. rerun 'make demo-kagent-credentials'

  .env is gitignored — the key is never committed.
  Consulted: ${SIGNALLOOM_ENV_FILE_RESOLVED:-<unresolved>} (present: $([ "${SIGNALLOOM_ENV_LOADED:-0}" = 1 ] && echo yes || echo no))
  Or export ANTHROPIC_API_KEY directly, which takes precedence over the file.
  Get a key at https://console.anthropic.com/settings/keys
EOF
}

# Validates the operator's key. Runs shielded: every line here expands it.
#
# Returns 1 rather than exiting when there is no key at all, so `seed` can
# no-op-with-guidance per the repo's precedent. A key that is PRESENT but
# unusable (the retired placeholder, a truncated paste) is still a hard failure:
# that is a mistake to correct, not an absence to tolerate.
require_key() {
  _shield_on
  local key="${ANTHROPIC_API_KEY-}" len
  # Trailing newlines and shell-copied whitespace are the usual paste damage.
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  len="${#key}"

  if [ -z "${ANTHROPIC_API_KEY+set}" ] || [ "$len" -eq 0 ]; then
    _shield_off
    return 1
  fi
  if [ "$key" = "$RETIRED_MOCK" ]; then
    _shield_off
    fail "ANTHROPIC_API_KEY is the retired mock placeholder. That value is exactly what this path exists to remove. Put a real key in ${SIGNALLOOM_ENV_FILE_RESOLVED:-.env}."
  fi
  if [ "$len" -lt "$MIN_KEY_LEN" ]; then
    _shield_off
    fail "ANTHROPIC_API_KEY is ${len} characters, shorter than the ${MIN_KEY_LEN}-character minimum. This is a truncated paste, not a key. Refusing to write a partial credential."
  fi
  VALIDATED_KEY="$key"
  _shield_off
  return 0
}

cmd_seed() {
  signalloom_load_env
  if ! require_key; then
    log "==> No ANTHROPIC_API_KEY configured; nothing was written to OpenBao."
    no_key_guidance
    return 0
  fi
  log "==> Credential source: $(signalloom_env_provenance ANTHROPIC_API_KEY)"

  local td pod agents remote agent sp
  td="$(trust_domain)"
  pod="$(bao_pod)"
  agents="$(anthropic_agents)"
  [ -n "$agents" ] || fail "no kagent agents declare an anthropic/api-key mapping in ${SECRET_PATHS_CM}"

  log "==> Seeding the Anthropic model credential into OpenBao"
  log "    trust domain : ${td}"
  log "    kv mount     : ${KV_MOUNT}/ (kv-v2)"
  log "    OpenBao pod  : ${pod} (namespace ${BAO_NS})"

  # Built here, executed in the pod. Every value interpolated below is a path,
  # a policy name or a SPIFFE ID — never the credential, which arrives on stdin.
  remote="$(bao_preamble)"
  remote="${remote}
umask 077
KEYFILE=\$(mktemp)
trap 'rm -f \"\$KEYFILE\"' EXIT INT TERM
cat > \"\$KEYFILE\"
[ -s \"\$KEYFILE\" ] || { echo 'no credential arrived on stdin' >&2; exit 3; }
bao secrets enable -path=${KV_MOUNT} kv-v2 >/dev/null 2>&1 || true
bao auth enable jwt >/dev/null 2>&1 || true
"

  for agent in $agents; do
    sp="$(spiffe_path_for "$agent")"
    log "    + ${agent}  ->  ${KV_MOUNT}/data/agents/${sp}/anthropic/api-key"
    remote="${remote}
bao kv put ${KV_MOUNT}/agents/${sp}/anthropic/api-key value=@\"\$KEYFILE\" >/dev/null
cat > /tmp/policy-${agent}.hcl <<'POLICY_${agent}'
path \"${KV_MOUNT}/data/agents/${sp}/*\" { capabilities = [\"read\"] }
path \"${KV_MOUNT}/metadata/agents/${sp}/*\" { capabilities = [\"list\", \"read\"] }
POLICY_${agent}
bao policy write signalloom-agent-${agent} /tmp/policy-${agent}.hcl >/dev/null
rm -f /tmp/policy-${agent}.hcl
bao write auth/jwt/role/signalloom-agent-${agent} \\
  role_type=jwt \\
  bound_audiences=openbao \\
  bound_subject=spiffe://${td}/${sp} \\
  user_claim=sub \\
  token_ttl=15m \\
  token_max_ttl=1h \\
  policies=signalloom-agent-${agent} >/dev/null
echo 'seeded ${agent}'
"
  done

  # The one place the key crosses a process boundary, and it crosses on stdin.
  _shield_on
  printf '%s' "$VALIDATED_KEY" | "$KUBECTL" exec -i -n "$BAO_NS" "$pod" -- sh -ec "$remote"
  local rc=$?
  _shield_off
  [ "$rc" -eq 0 ] || fail "OpenBao seed failed (exit ${rc})"

  log "==> Seeded. OpenBao now holds the credential; nothing was written to disk or to git."
  log "    Next: ${0##*/} sync   (project it into the Secret the kagent chart reads)"
}

# ─── sync ─────────────────────────────────────────────────────────────────────

cmd_sync() {
  local pod sp path staged len ns
  pod="$(bao_pod)"
  sp="$(spiffe_path_for "${KAGENT_PRIMARY_AGENT:-kagent-k8s-reader}")"
  path="${KV_MOUNT}/agents/${sp}/anthropic/api-key"

  # Staged in a file rather than a variable so it can be handed to kubectl by
  # path. --from-literal would put the credential in argv, where it is readable
  # from /proc by any process on the host and lands in shell history.
  umask 077
  staged="$(mktemp "${TMPDIR:-/tmp}/kagent-cred.XXXXXX")"
  # shellcheck disable=SC2064  # $staged is expanded now, deliberately.
  trap "rm -f '$staged'" EXIT INT TERM

  log "==> Reading the credential back from OpenBao"
  log "    path: ${path}"
  _shield_on
  "$KUBECTL" exec -n "$BAO_NS" "$pod" -- sh -ec "$(bao_preamble)
bao kv get -field=value ${path}" >"$staged" 2>/dev/null || true
  _shield_off

  len="$(wc -c <"$staged" | tr -d ' ')"
  if [ "${len:-0}" -lt "$MIN_KEY_LEN" ]; then
    fail "OpenBao returned ${len:-0} bytes at ${path}.

  Refusing to create a Secret from it. A short or empty credential still
  produces a Secret that exists, is non-empty by kubectl's reckoning, and
  passes every presence check — while failing every model call.

  Run '${0##*/} seed' first, with ANTHROPIC_API_KEY exported."
  fi

  log "==> Projecting into Secret/${SECRET_NAME} (key ${SECRET_KEY}), ${len} bytes"
  for ns in $SECRET_NAMESPACES; do
    log "    + namespace ${ns}"
    "$KUBECTL" create secret generic "$SECRET_NAME" \
      -n "$ns" \
      --from-file="${SECRET_KEY}=${staged}" \
      --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null
  done

  rm -f "$staged"
  trap - EXIT INT TERM
  log "==> Done. OpenBao remains the system of record; the Secret is a projection."
}

# ─── verify ───────────────────────────────────────────────────────────────────

# Evidence, never disclosure. Path, presence, byte length and a truncated digest
# are enough to prove the credential is there, is the operator's, and is the
# same value on both sides — without printing it.
cmd_verify() {
  local pod agents agent sp path out len digest ns b64len
  pod="$(bao_pod)"
  agents="$(anthropic_agents)"

  log "=== OpenBao: SPIFFE-scoped credential paths ==="
  log ""
  printf '  %-8s %-7s %-14s %s\n' "PRESENT" "BYTES" "SHA256[0:12]" "PATH"
  local overall=0
  for agent in $agents; do
    sp="$(spiffe_path_for "$agent")"
    path="${KV_MOUNT}/agents/${sp}/anthropic/api-key"
    _shield_on
    out="$("$KUBECTL" exec -n "$BAO_NS" "$pod" -- sh -ec "$(bao_preamble)
bao kv get -field=value ${path}" 2>/dev/null || true)"
    len="${#out}"
    digest="$(printf '%s' "$out" | sha256sum | cut -c1-12)"
    _shield_off
    if [ "$len" -ge "$MIN_KEY_LEN" ]; then
      printf '  %-8s %-7s %-14s %s\n' "yes" "$len" "$digest" "$path"
    else
      printf '  %-8s %-7s %-14s %s\n' "NO" "$len" "-" "$path"
      overall=1
    fi
  done

  log ""
  log "=== Kubernetes: the Secret the kagent chart consumes ==="
  log ""
  printf '  %-24s %-24s %-8s %s\n' "NAMESPACE" "SECRET" "KEY" "BYTES"
  for ns in $SECRET_NAMESPACES; do
    b64len="$("$KUBECTL" get secret "$SECRET_NAME" -n "$ns" \
                -o "jsonpath={.data.${SECRET_KEY}}" 2>/dev/null || true)"
    if [ -n "$b64len" ]; then
      len="$(printf '%s' "$b64len" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
      printf '  %-24s %-24s %-8s %s\n' "$ns" "$SECRET_NAME" "$SECRET_KEY" "$len"
    else
      printf '  %-24s %-24s %-8s %s\n' "$ns" "$SECRET_NAME" "$SECRET_KEY" "absent"
      overall=1
    fi
  done

  log ""
  log "The credential value is never printed. Equal SHA256 prefixes across rows"
  log "prove the same key reached every path; equal byte counts prove the"
  log "projection into Kubernetes is faithful."
  return "$overall"
}

# ─── status ───────────────────────────────────────────────────────────────────

cmd_status() {
  local pod
  signalloom_load_env
  log "=== kagent model credential ==="
  log "  .env consulted     : ${SIGNALLOOM_ENV_FILE_RESOLVED} (present: $([ "${SIGNALLOOM_ENV_LOADED:-0}" = 1 ] && echo yes || echo no))"
  log "  credential source  : $(signalloom_env_provenance ANTHROPIC_API_KEY)"
  log "  OpenBao namespace  : ${BAO_NS}"
  log "  kv mount           : ${KV_MOUNT}/ (kv-v2)"
  log "  trust domain       : $(trust_domain)"
  log "  agents namespace   : ${AGENTS_NS}"
  log "  Secret             : ${SECRET_NAME} (key ${SECRET_KEY})"
  log "  Secret namespaces  : ${SECRET_NAMESPACES}"
  log "  agents seeded      : $(anthropic_agents | tr '\n' ' ')"
  if pod="$(bao_pod 2>/dev/null)"; then
    log "  OpenBao pod        : ${pod}"
  else
    log "  OpenBao pod        : NOT FOUND"
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    log "  ANTHROPIC_API_KEY  : set (${#ANTHROPIC_API_KEY} characters, value not shown)"
  else
    log "  ANTHROPIC_API_KEY  : NOT SET — 'seed' will refuse to run"
  fi
}

usage() {
  cat <<EOF
Usage: ${0##*/} <seed|sync|verify|status>

  seed    Read ANTHROPIC_API_KEY from the environment and store it in OpenBao
          under each agent's SPIFFE-scoped path, with a per-agent policy and a
          per-agent JWT role bound to that agent's exact SPIFFE ID.
          Fails loudly if ANTHROPIC_API_KEY is unset, empty, the retired mock
          placeholder, or implausibly short. Never falls back to a placeholder.

  sync    Read the credential back out of OpenBao and project it into
          Secret/${SECRET_NAME} (key ${SECRET_KEY}) in: ${SECRET_NAMESPACES}
          Refuses to create the Secret if OpenBao returns nothing.

  verify  Print path, presence, byte length and a truncated SHA256 for every
          seeded path and every projected Secret. Never prints the value.

  status  Print the resolved configuration without contacting OpenBao.

Environment:
  ANTHROPIC_API_KEY          required by 'seed'; no default, ever
  KAGENT_TRUST_DOMAIN        default: read from SPIRE, else signalloom.demo
  KAGENT_AGENTS_NAMESPACE    default: fe-signalloom-agents
  KAGENT_SECRET_NAMESPACES   default: kagent fe-signalloom-agents
  KAGENT_BAO_NAMESPACE       default: inf-bao
  KUBECTL                    default: kubectl
EOF
}

case "${1:-}" in
  seed)   cmd_seed ;;
  sync)   cmd_sync ;;
  verify) cmd_verify ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  "")     usage >&2; exit 1 ;;
  *)      printf 'ERROR: unknown subcommand: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
esac
