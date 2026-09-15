#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# SLCD-P5-GOV end-to-end ingestion-to-render proof runner.
#
# Runs the merged Phase 5 pipeline for real: the signal-ingest ProtectedRouter
# on a real socket, the dashboard's real api client over real HTTP, and the
# real CodingAgentsTab rendering the result.
#
# Why a script rather than a bare `vitest` invocation:
#
#   Three environment facts have to be true BEFORE vitest boots, because the
#   api client reads them at module load and cannot be reconfigured afterwards:
#
#     VITE_SL_ENV          must NOT be 'demo'. demoMode.ts defaults demo mode
#                          ON when this is unset, and client.ts then answers
#                          every call from local fixtures without opening a
#                          socket -- a green run that proves nothing.
#     VITE_API_BASE_URL    is baked into the axios instance at import time.
#     SLCD_E2E_HARNESS_ADDR must agree with it exactly.
#
#   The port is chosen here, after checking it is free, so a leftover harness
#   from an earlier run cannot collide with this one.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
DASH_DIR="apps/dashboard-signalloom"
INGEST_DIR="$(cd apps/signal-ingest && pwd)"

# Find a free loopback port rather than hard-coding one.
pick_port() {
	python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

PORT="${SLCD_E2E_PORT:-$(pick_port)}"
ADDR="127.0.0.1:${PORT}"

GO_BIN="${SLCD_GO_BIN:-$(command -v go || true)}"
if [[ -z "${GO_BIN}" ]]; then
	echo "error: no 'go' binary found; set SLCD_GO_BIN" >&2
	exit 1
fi

echo "SLCD-P5-GOV e2e: harness on ${ADDR}, go=${GO_BIN}"

cd "${DASH_DIR}"
exec env \
	VITE_SL_ENV=ci \
	VITE_API_BASE_URL="http://${ADDR}" \
	SLCD_E2E_HARNESS_ADDR="${ADDR}" \
	SLCD_GO_BIN="${GO_BIN}" \
	SLCD_INGEST_ROOT="${INGEST_DIR}" \
	bunx vitest run --config vitest.e2e.config.ts "$@"
