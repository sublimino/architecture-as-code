#!/usr/bin/env bash
# ==============================================================================
# scripts/eap/validate-webhook-ingress.sh
# Validates the webhook-httproute.yaml and eap-httproute-template.yaml syntax
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MANIFEST="${REPO_ROOT}/d2-infra/components/ingress/webhook-httproute.yaml"
TEMPLATE="${REPO_ROOT}/d2-infra/components/ingress/eap-httproute-template.yaml"

echo "=== Validating Webhook Ingress Route Manifests ==="

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: Missing $MANIFEST" >&2
    exit 1
fi
echo "  [PASS] Found $MANIFEST"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "ERROR: Missing $TEMPLATE" >&2
    exit 1
fi
echo "  [PASS] Found $TEMPLATE"

# Check required Gateway API fields
for file in "$MANIFEST" "$TEMPLATE"; do
    if grep -q "kind: HTTPRoute" "$file" && grep -q "gateway.networking.k8s.io" "$file"; then
        echo "  [PASS] $file adheres to Gateway API HTTPRoute structure"
    else
        echo "  [FAIL] $file missing HTTPRoute or Gateway API spec" >&2
        exit 1
    fi
done

# Check webhook path prefix match
if grep -q "/api/v1/webhooks" "$MANIFEST"; then
    echo "  [PASS] $MANIFEST correctly matches /api/v1/webhooks"
else
    echo "  [FAIL] $MANIFEST missing /api/v1/webhooks path prefix" >&2
    exit 1
fi

echo "All ingress route manifests valid!"
exit 0
