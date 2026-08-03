#!/usr/bin/env bash
# check-flux-dynamic-labels.sh — fail if a runtime-owned field is declared in
# Flux-managed desired state.
#
# ─── Why this check exists ──────────────────────────────────────────────────
#
# `signalloom.ai/state` is written at runtime by the stun path and read by the
# dashboard. It was also declared as a literal (`signalloom.ai/state: idle`) in
# two Flux-managed manifests, which put it inside Flux's desired state.
#
# The consequence, measured on kind-osramp 2026-08-03:
#
#   kubectl label pod agent-cardvault signalloom.ai/state=stunned  -> stunned
#   <any reconcile of fe-signalloom/apps>
#   kubectl get pod agent-cardvault -o jsonpath=...state           -> idle
#
# The stun's credential revocation lives OUTSIDE the reconciled set, so it
# survived. The evidence of it did not. The dashboard therefore reported a
# still-revoked agent as healthy — the wrong direction for a monitoring error,
# and a live risk during a demo where an audience watches a second window.
#
# kustomize-controller v1.9.4 exposes no per-field drift ignore
# (`.spec.driftDetection` is absent from the CRD; `.spec.ignore` matches source
# paths, not fields), so "declare it and tell Flux to ignore it" is not
# available. The only correct fix is to not declare a runtime-owned field.
#
# This check makes that permanent: a field in DYNAMIC_FIELDS must never appear
# as a declared key in YAML under a Flux-managed path.
#
# ─── Adding a field ─────────────────────────────────────────────────────────
#
# If you introduce another label whose value is written at runtime, add it to
# DYNAMIC_FIELDS. The test is cheap and the failure it prevents is silent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Fields whose value is owned by the runtime, never by git.
DYNAMIC_FIELDS=(
  "signalloom.ai/state"
)

# Paths whose YAML is rendered by Flux (Kustomizations and flux-operator
# ResourceSets). A declaration anywhere in here is desired state.
FLUX_MANAGED_PATHS=(
  "d2-signalloom/apps"
  "d2-signalloom/infra"
  "d2-osramp-fleet"
)

red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

violations=0

for field in "${DYNAMIC_FIELDS[@]}"; do
  for path in "${FLUX_MANAGED_PATHS[@]}"; do
    [ -d "$path" ] || continue

    # Match the field only where it is DECLARED as desired state, i.e. under a
    # `labels:` block. Three things must NOT trip this:
    #
    #   1. Comments. The manifests carry long notes naming this exact field;
    #      flagging its own documentation would force whoever hit the check to
    #      delete the explanation to go green — the worst possible outcome.
    #   2. Selectors. `matchLabels: { signalloom.ai/state: stunned }` is the
    #      INTENDED use — it is how a quarantine NetworkPolicy targets stunned
    #      pods. Syntactically it is identical to a declaration, so context is
    #      the only way to tell them apart, and getting this wrong would make
    #      the checker reject the very control it exists to protect.
    #   3. `matchExpressions`, for the same reason.
    #
    # awk tracks the nearest enclosing block key by indentation, so the
    # decision is made on structure rather than on a fragile line regex.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      red "  ✗ ${hit}"
      violations=$((violations + 1))
    done < <(
      while IFS= read -r file; do
        awk -v field="$field" -v fname="$file" '
          # Remember the most recent block key at each indent depth.
          /^[[:space:]]*#/ { next }
          match($0, /^[[:space:]]*/) {
            indent = RLENGTH
          }
          /^[[:space:]]*[A-Za-z][A-Za-z0-9_]*:[[:space:]]*$/ {
            key = $0
            sub(/^[[:space:]]*/, "", key)
            sub(/:[[:space:]]*$/, "", key)
            block[indent] = key
            # Deeper stale entries are no longer in scope.
            for (i in block) if (i > indent) delete block[i]
            next
          }
          {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ "^" field "[[:space:]]*:[[:space:]]*[^[:space:]]") {
              # Nearest enclosing block is the deepest recorded key shallower
              # than this line.
              best = -1; ctx = ""
              for (i in block) if (i + 0 < indent && i + 0 > best) { best = i + 0; ctx = block[i] }
              if (ctx != "matchLabels" && ctx != "matchExpressions") {
                printf "%s:%d: %s   (in `%s:` block)\n", fname, NR, line, (ctx == "" ? "top-level" : ctx)
              }
            }
          }
        ' "$file"
      done < <(find "$path" \( -name '*.yaml' -o -name '*.yml' \) -type f 2>/dev/null)
    )
  done
done

if [ "$violations" -ne 0 ]; then
  red ""
  red "FAILED: ${violations} runtime-owned field(s) declared in Flux-managed desired state."
  red ""
  red "A field Flux declares is a field Flux reverts. For a label the stun path"
  red "writes, that silently erases the evidence of a live containment while the"
  red "containment itself persists — the dashboard then reports a revoked agent"
  red "as healthy."
  red ""
  red "Fix: delete the declaration. The runtime sets the value; consumers treat"
  red "an absent label as 'no observation yet', which is honest. Do not try to"
  red "keep the declaration and exempt it — kustomize-controller v1.9.4 has no"
  red "per-field drift ignore."
  exit 1
fi

green "✓ no runtime-owned fields declared in Flux-managed desired state"
green "  checked: ${DYNAMIC_FIELDS[*]}"
green "  under:   ${FLUX_MANAGED_PATHS[*]}"
