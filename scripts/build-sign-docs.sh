#!/usr/bin/env bash
# Build the Signal Loom documentation image through the shared signed-image path.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKLOAD=docs-signalloom \
IMAGE_REF="${IMAGE_REF:-zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/docs-signalloom:latest}" \
LOCAL_REF="${LOCAL_REF:-localhost:5001/acme/images/signalloom/apps/docs-signalloom:latest}" \
CONTEXT="${CONTEXT:-d2-signalloom/apps/docs-signalloom}" \
"${ROOT_DIR}/scripts/build-sign-dashboard.sh"
