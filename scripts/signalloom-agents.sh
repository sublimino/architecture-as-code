#!/usr/bin/env bash
# Manage the ephemeral demo-agent cohort in the fe-signalloom-agents namespace.
#
#   signalloom-agents.sh up [N]   delete the current cohort, create N fresh
#                                 inert podinfo "agents" with random Monty Python
#                                 names (default N=4).
#   signalloom-agents.sh down     delete the ephemeral cohort.
#   signalloom-agents.sh list     show all agents in the namespace.
#
# The Flux-managed baseline agent (agent-sir-lancelot) is NOT touched — only the
# cohort labelled signalloom.ai/agent-cohort=ephemeral is created/deleted, so
# Flux never fights this script. Agents are inert; only their metadata is read.
set -euo pipefail

NS="${AGENTS_NAMESPACE:-fe-signalloom-agents}"
COHORT_SELECTOR="signalloom.ai/agent-cohort=ephemeral"
KUBECTL="${KUBECTL:-kubectl}"

# name | display | type | framework | model | model-full | description
AGENTS=(
  "brian|Brian of Nazareth|custom|langgraph|gpt-4o|openai/gpt-4o|Not the Messiah — a very naughty agent."
  "black-knight|The Black Knight|cots|none|llama-3-70b|meta/llama-3-70b|Tis but a scratch; refuses to concede failure."
  "tim-the-enchanter|Tim the Enchanter|signal-loom-built|kagent|claude-sonnet-4-6|anthropic/claude-sonnet-4-6|Summons fire without flint or tinder."
  "sir-galahad|Sir Galahad the Pure|signal-loom-built|kagent|claude-opus-4-8|anthropic/claude-opus-4-8|Chaste, until the Castle Anthrax."
  "king-arthur|King Arthur|custom|langgraph|gpt-4o|openai/gpt-4o|King of the Britons; rides an imaginary horse."
  "sir-robin|Sir Robin the Not-Quite-So-Brave|cots|none|mistral-large|mistralai/mistral-large|Bravely runs away from exceptions."
  "patsy|Patsy|cots|none|gpt-4o-mini|openai/gpt-4o-mini|Bangs the coconuts. Does the actual work."
  "roger-the-shrubber|Roger the Shrubber|custom|langgraph|llama-3-8b|meta/llama-3-8b|Arranges, designs, and sells shrubberies."
  "dennis|Dennis the Peasant|signal-loom-built|kagent|claude-haiku-4-5|anthropic/claude-haiku-4-5|Anarcho-syndicalist commune member, age 37."
)

ensure_ns() { "$KUBECTL" get namespace "$NS" >/dev/null 2>&1 || "$KUBECTL" create namespace "$NS" >/dev/null; }

delete_cohort() {
  "$KUBECTL" -n "$NS" delete pods -l "$COHORT_SELECTOR" --ignore-not-found --wait=true >/dev/null 2>&1 || true
}

create_agent() {
  local slug="$1" display="$2" atype="$3" framework="$4" model="$5" model_full="$6" desc="$7"
  "$KUBECTL" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: agent-${slug}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: signalloom-agent
    app.kubernetes.io/component: agent
    app.kubernetes.io/part-of: signalloom
    app.kubernetes.io/managed-by: signalloom-agents-script
    app.kubernetes.io/instance: ${slug}
    signalloom.ai/agent: "true"
    signalloom.ai/agent-name: ${slug}
    signalloom.ai/agent-type: ${atype}
    signalloom.ai/framework: ${framework}
    signalloom.ai/model: ${model}
    signalloom.ai/state: idle
    signalloom.ai/agent-cohort: ephemeral
  annotations:
    signalloom.ai/agent-display-name: "${display}"
    signalloom.ai/model-full: "${model_full}"
    signalloom.ai/description: "${desc}"
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: agent
      image: ghcr.io/stefanprodan/podinfo:6.7.1
      ports:
        - name: http
          containerPort: 9898
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: data
          mountPath: /data
      resources:
        requests:
          cpu: 5m
          memory: 16Mi
        limits:
          memory: 64Mi
  volumes:
    - name: tmp
      emptyDir: {}
    - name: data
      emptyDir: {}
EOF
  echo "  + ${display} (${slug}) [${atype} / ${framework} / ${model}]"
}

cmd="${1:-up}"
count="${2:-4}"

case "$cmd" in
  up)
    ensure_ns
    echo "==> Removing current ephemeral agent cohort in ${NS}..."
    delete_cohort
    echo "==> Creating ${count} fresh agent(s)..."
    # Random distinct selection from the roster.
    mapfile -t picked < <(printf '%s\n' "${AGENTS[@]}" | shuf | head -n "${count}")
    for entry in "${picked[@]}"; do
      IFS='|' read -r slug display atype framework model model_full desc <<<"$entry"
      create_agent "$slug" "$display" "$atype" "$framework" "$model" "$model_full" "$desc"
    done
    echo "==> Done. Discover via GET /api/agents (compliance/posture render as 0 — unconfigured)."
    ;;
  down)
    echo "==> Removing ephemeral agent cohort in ${NS}..."
    delete_cohort
    echo "==> Done (Flux-managed baseline agent, if any, is preserved)."
    ;;
  list)
    "$KUBECTL" -n "$NS" get pods -l "signalloom.ai/agent=true" \
      -L signalloom.ai/agent-name,signalloom.ai/agent-type,signalloom.ai/framework,signalloom.ai/agent-cohort 2>&1
    ;;
  *)
    echo "usage: $0 [up N|down|list]" >&2
    exit 64
    ;;
esac
