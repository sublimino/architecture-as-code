#!/usr/bin/env bash
# check-flux-dynamic-labels.sh — a runtime-owned field must be DECLARED in the
# manifest AND IGNORED by the Kustomization. Both, or the stun breaks.
#
# ─── Why this check exists, and why it was inverted ─────────────────────────
#
# `signalloom.ai/state` and the two stun annotations are written at runtime by
# the stun path and read by the dashboard. Three configurations are possible and
# only one works. Measured on kind-osramp with a matched control
# (`docs/signalloom/_research-flux-ignore.md`, TEST G / TEST H):
#
#   declared, NOT ignored      -> all three reverted on reconcile   (the original bug)
#   NOT declared, ignore rule  -> annotations WIPED, label DELETED  (STRICTLY WORSE)
#   declared AND ignored       -> label and both annotations survive (correct)
#
# `.spec.ignore` works by substituting the LIVE value at each ignored path into
# the desired object before apply. A path the manifest never declares has
# nothing to substitute into, so it is dropped entirely — which is why removing
# the declaration is worse than the bug it was meant to fix: the dashboard
# cannot even show a stale value, and "never stunned" becomes indistinguishable
# from "stun erased".
#
# THIS CHECK PREVIOUSLY ENFORCED THE FALSIFIED OPTION. It required the field to
# be absent, which blocked the correct configuration in CI. A cross-vendor audit
# caught it: the docs carried the correction while the code and the gate still
# implemented the retracted conclusion. The lesson is in the failure message.
#
# ─── Adding a field ─────────────────────────────────────────────────────────
#
# Add it to DYNAMIC_FIELDS and add its JSON Pointer to the Kustomization's
# `.spec.ignore`. The check will tell you if you do only one.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${CHECK_ROOT:-$REPO_ROOT}"

# Fields whose value is owned by the runtime, not by git.
DYNAMIC_FIELDS=(
  "signalloom.ai/state"
  "signalloom.ai/stunned-at"
  "signalloom.ai/stun-reason"
)

# Where Flux-rendered manifests live.
FLUX_MANAGED_PATHS=("d2-signalloom/apps" "d2-signalloom/infra" "d2-osramp-fleet")

# Where `.spec.ignore` rules are declared.
IGNORE_RULE_PATHS=("d2-osramp-fleet")

red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# A declaration is `<field>: <value>` under a `labels:`/`annotations:` block.
# A SELECTOR (`matchLabels`, `matchExpressions`) is syntactically identical and
# must NOT count — a quarantine NetworkPolicy legitimately selects on the field.
declarations_of() {
  local field="$1" path
  for path in "${FLUX_MANAGED_PATHS[@]}"; do
    [ -d "$path" ] || continue
    while IFS= read -r file; do
      awk -v field="$field" -v fname="$file" '
        /^[[:space:]]*#/ { next }
        match($0, /^[[:space:]]*/) { indent = RLENGTH }
        /^[[:space:]]*[A-Za-z][A-Za-z0-9_]*:[[:space:]]*$/ {
          key = $0; sub(/^[[:space:]]*/, "", key); sub(/:[[:space:]]*$/, "", key)
          block[indent] = key
          for (i in block) if (i > indent) delete block[i]
          next
        }
        {
          line = $0; sub(/^[[:space:]]*/, "", line)
          if (line ~ "^" field "[[:space:]]*:") {
            best = -1; ctx = ""
            for (i in block) if (i + 0 < indent && i + 0 > best) { best = i + 0; ctx = block[i] }
            if (ctx != "matchLabels" && ctx != "matchExpressions")
              printf "%s:%d\n", fname, NR
          }
        }
      ' "$file"
    done < <(find "$path" \( -name '*.yaml' -o -name '*.yml' \) -type f 2>/dev/null)
  done
}

# JSON Pointer for a label/annotation key: `/` inside the key escapes to `~1`.
ignored_paths_for() {
  local field="$1" escaped path
  escaped="${field//\//\~1}"
  for path in "${IGNORE_RULE_PATHS[@]}"; do
    [ -d "$path" ] || continue
    grep -rlF -- "$escaped" "$path" --include='*.yaml' --include='*.yml' 2>/dev/null || true
  done
}

violations=0
for field in "${DYNAMIC_FIELDS[@]}"; do
  decls="$(declarations_of "$field")"
  ign="$(ignored_paths_for "$field")"

  if [ -z "$decls" ]; then
    red "  ✗ ${field}: NOT DECLARED in any Flux-managed manifest"
    red "      Without a declaration the ignore rule has no path to preserve, so the"
    red "      field is dropped entirely on apply — measured strictly worse than the bug."
    violations=$((violations + 1))
    continue
  fi

  if [ -z "$ign" ]; then
    red "  ✗ ${field}: declared but NO .spec.ignore rule covers it"
    while IFS= read -r d; do [ -n "$d" ] && red "      declared at ${d}"; done <<< "$decls"
    red "      Add /metadata/{labels,annotations}/${field//\//\~1} to the Kustomization's .spec.ignore."
    violations=$((violations + 1))
  fi
done

if [ "$violations" -ne 0 ]; then
  red ""
  red "FAILED: ${violations} runtime-owned field(s) misconfigured."
  red ""
  red "The rule is BOTH, not either: declared in the manifest AND ignored by the"
  red "Kustomization. Declared-without-ignore reverts on reconcile; ignored-without-"
  red "declaration deletes the field outright. Only the pair survives."
  red ""
  red "Evidence: docs/signalloom/_research-flux-ignore.md, TEST G with control TEST H."
  exit 1
fi

green "✓ every runtime-owned field is declared AND covered by a .spec.ignore rule"
green "  fields: ${DYNAMIC_FIELDS[*]}"
