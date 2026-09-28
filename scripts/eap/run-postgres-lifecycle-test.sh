#!/usr/bin/env bash
# ==============================================================================
# SLRC-P2-2: live PostgreSQL lifecycle store verification.
#
# Runs d2-signalloom/apps/fe-signalloom/src/tests/
# test_environment_lifecycle_store_integration.py against a real, isolated
# PostgreSQL with ZERO skips, and writes a reviewable evidence JSON.
#
#   1. DATABASE_URL set   -> use it (must be loopback unless
#                            SLRC_ALLOW_NON_LOOPBACK_PG=1; the role needs CREATEDB).
#      DATABASE_URL unset -> start a card-owned postgres:16-alpine container
#                            (label slrc-card=P2-2, 127.0.0.1 ephemeral port,
#                            random password) and remove it on exit.
#   2. Migration probe: apply the full chain (incl. 043) to an empty scratch
#      database twice; the second apply must be a no-op.
#   3. pytest with junit + per-test metrics; any skip, failure, error, or an
#      empty collection is a non-zero exit.
#   4. Assemble docs/signalloom/evidence/slrc-p2-postgres-evidence.json
#      (override with SLRC_P2_EVIDENCE_OUT). The password is never written.
#
# Python runner: SLRC_PYTHON (an interpreter with asyncpg, pytest,
# pytest-asyncio and requirements.txt installed) or, by default, `uv run`.
# Extra arguments are passed to pytest (e.g. -k test_concurrent_claims).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_SRC="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src"
TEST_FILE="tests/test_environment_lifecycle_store_integration.py"
EVIDENCE_OUT="${SLRC_P2_EVIDENCE_OUT:-${REPO_ROOT}/docs/signalloom/evidence/slrc-p2-postgres-evidence.json}"
PG_IMAGE="${SLRC_PG_IMAGE:-postgres:16-alpine}"
READY_TIMEOUT="${SLRC_PG_READY_TIMEOUT:-60}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/slrc-p2-2.XXXXXX")"
CONTAINER=""

log() { printf '[slrc-p2-2] %s\n' "$*" >&2; }
die() { log "FAIL: $*"; exit 1; }

cleanup() {
  local status=$?
  if [[ -n "${CONTAINER}" ]]; then
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || log "WARN: could not remove container ${CONTAINER}"
  fi
  rm -rf "${WORK_DIR}"
  exit "${status}"
}
trap cleanup EXIT
# Route signals through exit so the EXIT trap removes the container on a kill.
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "${SLRC_PYTHON:-}" ]]; then
  PY=("${SLRC_PYTHON}")
else
  command -v uv >/dev/null 2>&1 || die "neither SLRC_PYTHON nor uv is available"
  PY=(uv run --quiet --python 3.12 --with pytest --with pytest-asyncio
      --with-requirements "${APP_SRC}/requirements.txt" python)
fi

# --- 1. database -------------------------------------------------------------
PG_SOURCE="caller"
if [[ -z "${DATABASE_URL:-}" ]]; then
  command -v docker >/dev/null 2>&1 || die "DATABASE_URL unset and docker unavailable"
  PG_SOURCE="card-owned-container"
  CONTAINER="slrc-p22-pg-$$-${RANDOM}"
  password="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  log "starting ${PG_IMAGE} as ${CONTAINER}"
  docker run -d --rm --name "${CONTAINER}" --label slrc-card=P2-2 \
    -e POSTGRES_USER=slrc -e POSTGRES_PASSWORD="${password}" -e POSTGRES_DB=slrc \
    -p 127.0.0.1::5432 "${PG_IMAGE}" >/dev/null
  host_port="$(docker port "${CONTAINER}" 5432/tcp | head -n1)"
  [[ "${host_port}" == 127.0.0.1:* ]] || die "container not bound to loopback: ${host_port}"
  # -h 127.0.0.1: the image's init-phase server listens on the unix socket
  # only, so a TCP probe does not report ready until the final server is up.
  deadline=$((SECONDS + READY_TIMEOUT))
  until docker exec "${CONTAINER}" pg_isready -q -h 127.0.0.1 -U slrc -d slrc; do
    (( SECONDS < deadline )) || die "postgres not ready after ${READY_TIMEOUT}s"
    sleep 0.5
  done
  export DATABASE_URL="postgresql://slrc:${password}@${host_port}/slrc"
fi

"${PY[@]}" - <<'PY' || die "refusing non-loopback DATABASE_URL (set SLRC_ALLOW_NON_LOOPBACK_PG=1 to override)"
import os, sys
from urllib.parse import urlsplit
host = urlsplit(os.environ["DATABASE_URL"]).hostname or ""
ok = host in {"127.0.0.1", "localhost", "::1"} or os.environ.get("SLRC_ALLOW_NON_LOOPBACK_PG") == "1"
sys.exit(0 if ok else 1)
PY

export SLRC_PG_SOURCE="${PG_SOURCE}" SLRC_PG_CONTAINER="${CONTAINER}" SLRC_PG_IMAGE="${PG_IMAGE}"

# --- 2. migration probe ------------------------------------------------------
log "verifying migration chain (incl. 043) on an empty scratch database"
(cd "${APP_SRC}" && "${PY[@]}" "${SCRIPT_DIR}/verify_lifecycle_migration.py" \
  --out "${WORK_DIR}/migration.json") || die "migration probe failed"

# --- 3. integration suite ----------------------------------------------------
export SLRC_LIFECYCLE_METRICS_OUT="${WORK_DIR}/metrics.jsonl"
: > "${SLRC_LIFECYCLE_METRICS_OUT}"
log "running ${TEST_FILE}"
set +e
(cd "${APP_SRC}" && "${PY[@]}" -m pytest "${TEST_FILE}" -v -rs -p no:cacheprovider \
  --junitxml="${WORK_DIR}/junit.xml" "$@") 2>&1 | tee "${WORK_DIR}/pytest.log"
pytest_status=${PIPESTATUS[0]}
set -e
log "pytest exit status ${pytest_status}"

# --- 4. evidence + zero-skip gate -------------------------------------------
"${PY[@]}" "${SCRIPT_DIR}/assemble_postgres_lifecycle_evidence.py" \
  --junit "${WORK_DIR}/junit.xml" --metrics "${SLRC_LIFECYCLE_METRICS_OUT}" \
  --migration "${WORK_DIR}/migration.json" --pytest-log "${WORK_DIR}/pytest.log" \
  --pytest-status "${pytest_status}" --pytest-args "$*" --out "${EVIDENCE_OUT}"
log "evidence written to ${EVIDENCE_OUT}"
