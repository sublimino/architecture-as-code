#!/usr/bin/env bats
# d2-signalloom/test/agents-redesign-evidence.bats
#
# SFAGENTS-P1-3: Error Handling & Scale Normalization evidence assertions.
# - RFC 9110 idempotent/side-effect free GET endpoints (zero writes on GET /api/audit, GET /api/agents)
# - HTTP 404 on unknown agent IDs (no synthetic _synth_agent fallback)
# - Explicit source_health header / envelope metadata
# - Fail-closed HTTP 503 on collector outage (GET /api/health/crypto)
# - Scale normalization: posture_score in 0.0-1.0 or None
# - Migration 033 idempotency and quarantine safety

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SRC_DIR="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src"
  DASHBOARD_DIR="${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom"
  export UV_CONFIG_FILE=/dev/null
  export UV_CACHE_DIR=/tmp/uv-cache
}

@test "sfagents-p1-3: migration 033 quarantine is idempotent and non-destructive" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_migrations.py"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-3: GET /api/audit is side-effect-free and idempotent under RFC 9110" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_audit_get_is_strictly_side_effect_free'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-3: GET /api/agents/{id} returns 404 for unknown agent IDs without synthesizing" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_agent_detail_returns_404_for_unknown_agent'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-3: GET /api/health/crypto fails closed with 503 on collector outage" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_source_health_crypto_prover_fails_closed_with_503'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-3: source_health headers and metadata are emitted on collector endpoints" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_source_health_header_and_metadata_emitted_on_agents_get'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-3: posture score scale normalization is strictly 0.0-1.0 or None" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_posture_scale_normalized_zero_controls_is_none'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-3: dashboard Vitest suite passes 100% including truthful UI labels and kernel telemetry" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/pages/AgentsPage.test.tsx src/pages/SwarmAgentsPage.test.tsx src/api/demoMode.test.ts"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-4: GET /api/agents preserves discovery metadata (namespace, SA, node, pod_uid, framework, phase)" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_enriched_inventory_preserves_discovery_fields'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-4: GET /api/agents server-side search, namespace, framework, and attention filters" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_enriched_inventory_server_side_search_and_filters'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-4: GET /api/agents pagination and meta metrics breakdown" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_enriched_inventory_pagination_and_meta'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-4: GET /api/agents is strictly side-effect free (zero writes)" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_enriched_inventory_get_is_strictly_side_effect_free'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-6: operational inventory table renders 7-column headers and 4 StatCards in Vitest" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/pages/AgentsPage.test.tsx -t '7-Column Operational Inventory Table|4 StatCards'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-6: truthful language dictionary asserts 'Not assessed', 'Unassigned', 'Registry not linked'" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/pages/AgentsPage.test.tsx -t 'Truthful Language Dictionary'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-6: kernel containment telemetry displays FROZEN/DROP and requested unconfirmed states" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/pages/AgentsPage.test.tsx -t 'Kernel Containment Telemetry'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-6: backend operational inventory response envelope models pass contract" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_operational_inventory_response_envelope_and_models'"
  [ "$status" -eq 0 ]
}

