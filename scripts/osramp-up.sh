#!/usr/bin/env bash
# osramp-up.sh — Restore OSRAMP application to the cluster.
# Restores the ResourceSet inputs and triggers reconciliation.
# Requires: images already loaded into kind (run `make images` if needed).

set -eo pipefail

# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

NAMESPACES=("frontend" "backend")
RESOURCESET="apps"
FLUX_NS="flux-system"
INPUTS_FILE="${OSRAMP_INPUTS_FILE:-/tmp/.osramp-resourceset-inputs.json}"

# Default inputs if saved file doesn't exist
DEFAULT_INPUTS='[{"artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","environment":"local","tag":"latest","tenant":"frontend"},{"artifactSubjectGitRef":"local","artifactSubjectWorkflow":"local","environment":"local","tag":"latest","tenant":"backend"}]'

valid_inputs() {
  jq -e '
    type == "array" and length > 0 and
    all(.[];
      . as $input |
      type == "object" and
      all(["tenant", "environment", "tag", "artifactSubjectWorkflow", "artifactSubjectGitRef"][];
        . as $key | ($input[$key] | type == "string" and length > 0)))
  ' >/dev/null 2>&1
}

CURRENT_INPUTS=$(kubectl get resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  -o jsonpath='{.spec.inputs}') || {
  echo "ERROR: ResourceSet '${RESOURCESET}' is unavailable." >&2
  exit 1
}

PATCH_INPUTS=false
if valid_inputs <<<"${CURRENT_INPUTS}"; then
  echo "==> Preserving current ResourceSet inputs..."
elif [ -z "${CURRENT_INPUTS}" ] || \
    jq -e '(. == null) or (type == "array" and length == 0)' \
      <<<"${CURRENT_INPUTS}" >/dev/null 2>&1; then
  PATCH_INPUTS=true
  if [ -f "${INPUTS_FILE}" ] && [ -s "${INPUTS_FILE}" ]; then
    INPUTS=$(<"${INPUTS_FILE}")
    echo "==> Restoring ResourceSet inputs from saved file..."
  else
    INPUTS="${DEFAULT_INPUTS}"
    echo "==> Using default ResourceSet inputs (no saved file found)..."
  fi
  if ! valid_inputs <<<"${INPUTS}"; then
    echo "ERROR: ResourceSet inputs must be a valid non-empty JSON input array." >&2
    exit 1
  fi
else
  echo "ERROR: Current ResourceSet inputs are invalid; refusing to overwrite them." >&2
  exit 1
fi

# The ResourceSet ships with fluxcd.controlplane.io/reconcile: disabled, which
# the controller checks (obj.IsDisabled()) and returns on BEFORE building. That
# is the operator's actual off-switch; `inputs: []` is not one, because an empty
# input list makes BuildResourceSet render once against a nil map and stall on
# the first `<< inputs.tenant >>`. Patching inputs without clearing this first
# is a silent no-op — the patch succeeds and the controller still skips.
echo "==> Enabling reconciliation for ResourceSet '${RESOURCESET}'..."
kubectl annotate resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  fluxcd.controlplane.io/reconcile-

if [ "${PATCH_INPUTS}" = true ]; then
  echo "==> Patching ResourceSet '${RESOURCESET}' with inputs..."
  kubectl patch resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
    --type merge -p "{\"spec\":{\"inputs\":${INPUTS}}}"
fi

echo "==> Triggering immediate reconciliation..."
kubectl annotate resourceset "${RESOURCESET}" -n "${FLUX_NS}" \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite

echo "==> Waiting for ResourceSet '${RESOURCESET}' to become Ready..."
wait_flux_ready resourceset "${RESOURCESET}" -n "${FLUX_NS}" 300

echo "==> Waiting for namespaces to appear..."
for ns in "${NAMESPACES[@]}"; do
  wait_k8s_exists namespace "${ns}" 120
done

echo "==> Waiting for Kustomizations to become Ready..."
for ns in "${NAMESPACES[@]}"; do
  wait_flux_ready kustomization apps -n "${ns}" 300
done

echo "==> Pod status:"
for ns in "${NAMESPACES[@]}"; do
  echo "    --- ${ns} ---"
  kubectl get pods -n "${ns}" --no-headers 2>/dev/null | \
    awk '{printf "    %-55s %-7s %s\n", $1, $3, $4}'
done

echo ""
echo "==> OSRAMP restored (frontend + backend)."
echo "    If pods show ErrImageNeverPull, run: make images"
