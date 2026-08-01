#!/usr/bin/env bash
# Hold a single Zot port-forward open for the duration of COMMAND, so a batch
# of image pushes reuses one connection instead of opening one per image. If the
# registry is already reachable on the local port, COMMAND runs against the
# existing forward and nothing is started or torn down.
#
# Usage: with-zot-portforward.sh COMMAND [ARG...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh"

LOCAL_PORT="${ZOT_LOCAL_PORT:-5001}"
NAMESPACE="${ZOT_NAMESPACE:-registry}"
SERVICE="${ZOT_SERVICE:-svc/zot}"
REGISTRY_URL="http://localhost:${LOCAL_PORT}/v2/"

if [[ $# -eq 0 ]]; then
  echo "usage: $(basename "$0") COMMAND [ARG...]" >&2
  exit 2
fi

# Already reachable (a forward is up, or another wrapper owns it): reuse it.
if curl -fsS "${REGISTRY_URL}" >/dev/null 2>&1; then
  exec "$@"
fi

kubectl -n "${NAMESPACE}" port-forward "${SERVICE}" "${LOCAL_PORT}:5000" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

# Deadline-driven, jittered readiness wait (replaces a fixed 30s poll loop).
# Tolerant of cold image pulls and CPU/memory pressure; stretch every wait in
# the suite with WAIT_DEADLINE_SCALE, or just this one with ZOT_WAIT_DEADLINE.
wait_reachable "${REGISTRY_URL}" "${ZOT_WAIT_DEADLINE:-90}"

"$@"
