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

@test "sfagents-p1-5: GET /api/capabilities returns server-authorized capabilities per tenant and role" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_capabilities_for_operator_user or test_capabilities_for_superadmin_user'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-5: GET /api/capabilities supports workload-scoped capabilities and returns 404 for unknown agents" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_capabilities_workload_scoped or test_capabilities_returns_404'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-5: GET /api/capabilities is strictly side-effect free (zero SQL writes)" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_capabilities_get_is_strictly_side_effect_free'"
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

@test "sfagents-p1-7: AgentEvidenceDrawer component vitest suite passes 100% with truthful labels and telemetry" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentEvidenceDrawer.test.tsx"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-7: Quick Evidence Side Drawer integration tests pass in AgentsPage" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/pages/AgentsPage.test.tsx -t 'Quick Evidence Side Drawer'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-7: backend AgentResponse models with drawer telemetry and metadata pass contract" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_agent_response_model_with_drawer_telemetry_and_metadata'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p1-7: GET /api/agents/{id} detail endpoint is strictly side-effect free under RFC 9110" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_agent_detail_get_is_strictly_side_effect_free'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-1: /agents/:id route and 5-tab Dossier navigation Vitest suite passes 100%" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/pages/AgentDetailPage.test.tsx -t 'Dossier Route & 5-Tab Navigation'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-1: Tab 1 Overview summary grid and 4 StatCards pass Vitest suite" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentOverviewTab.test.tsx -t '4 Summary StatCards'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-1: Tab 1 truthful state language asserts 'Not assessed', 'Unassigned', 'Registry not linked'" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentOverviewTab.test.tsx src/pages/AgentDetailPage.test.tsx -t 'truthful|Truthful'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-1: Tab 1 kernel containment telemetry asserts eBPF sentinel and TC drop observations" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentOverviewTab.test.tsx src/pages/AgentDetailPage.test.tsx -t 'Kernel Containment|kernel telemetry'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-1: Tab 1 Overview 3 snapshot detail panels render metadata and health" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentOverviewTab.test.tsx -t '3 Snapshot Detail Panels'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-1: GET /api/agents/{id} detail endpoint preserves all Tab 1 metadata structures" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_dossier_detail_preserves_all_tab1_metadata'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-1: GET /api/agents/{unknown_id} returns HTTP 404 without synthesizing fake records" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_dossier_unknown_id_fails_closed_with_404'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-2: Tab 2 (Identity) component Vitest suite passes 100%" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentIdentityTab.test.tsx"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-2: Tab 2 SVID selectors and workload binding pass Vitest suite" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentIdentityTab.test.tsx -t 'SVID Selectors & Workload Binding'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-2: Tab 2 delegation chain asserts separation of identity planes (authorizing principal vs executing actor)" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentIdentityTab.test.tsx -t 'Delegation Chain & Separation of Identity Planes'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-2: Tab 2 truthful state language asserts 'Identity unlinked', 'Registry not linked', 'Unassigned', 'Source unavailable'" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentIdentityTab.test.tsx -t 'Truthful State Language & Error Handling'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-2: Tab 2 AgentDetailPage integration renders Identity tab panel in Vitest" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/pages/AgentDetailPage.test.tsx -t 'Tab 2 (Identity & SPIFFE Integration)'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-2: GET /api/agents/{id} returns enriched Tab 2 IdentityMetadata structures in Pytest" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_dossier_identity_spiffe_metadata_enrichment or test_dossier_identity_separation_of_planes'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-2: GET /api/agents/{id} identity queries are strictly side-effect free under RFC 9110" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_dossier_identity_get_is_strictly_side_effect_free'"
  [ "$status" -eq 0 ]
}



@test "sfagents-p2-3: Tab 3 (Access & Containment) 3 independent containment tracks and StatCards pass Vitest" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentAccessTab.test.tsx -t '3 Independent Containment Tracks|overview StatCards'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-3: Tab 3 server-authorized action capabilities and RBAC pass Vitest" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentAccessTab.test.tsx -t 'Server-Authorized Action Capabilities'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-3: Tab 3 truthful state language asserts 'Not assessed', 'Unassigned', 'Registry not linked', 'Source unavailable'" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentAccessTab.test.tsx -t 'Truthful Language Dictionary'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-3: Tab 3 /agents/:id?tab=access deep link navigation renders in AgentDetailPage Vitest" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/pages/AgentDetailPage.test.tsx -t 'Access & Containment Tab'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-3: backend GET /api/capabilities and containment tracks pass Pytest contract" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_tab3_access_containment_tracks_models_and_telemetry or test_tab3_capabilities_workload_scoped_rbac_and_invariants'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-3: backend GET /api/capabilities is strictly side-effect free under RFC 9110" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_tab3_capabilities_is_strictly_side_effect_free_under_rfc9110'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-4: Tab 4 (Assessments & Control Ratios) Vitest suite passes 100%" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentAssessmentsTab.test.tsx src/pages/AgentDetailPage.test.tsx -t 'Tab 4'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-4: Tab 4 truthful state language asserts 'Not assessed' and 'Source unavailable'" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentAssessmentsTab.test.tsx -t 'truthful|Not assessed|Source unavailable'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-4: Tab 4 EU AI Act Article 9 breakdown renders risk class and requirement ratios" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentAssessmentsTab.test.tsx -t 'Article 9'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-4: GET /api/compliance/posture is strictly side-effect free under RFC 9110" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_tab4_compliance_posture_is_side_effect_free'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-4: GET /api/compliance/frameworks returns EU AI Act and Article 9 controls" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_tab4_compliance_frameworks_returns_article9'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-4: POST /api/agents/{id}/compliance/{control_id}/reassess records audit truthfully" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_tab4_compliance_reassess_records_audit_honestly'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-4: GET /api/agents/{id} detail endpoint preserves assessment_summary structure" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_tab4_agent_detail_preserves_assessment_summary'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-5: Tab 5 Activity & Attributable Timeline Vitest suite passes 100%" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentActivityTab.test.tsx"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-5: Tab 5 renders all 4 summary StatCards with accurate counts and stream status" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentActivityTab.test.tsx -t '4 summary StatCards'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-5: Tab 5 enforces identity plane separation and truthful state language" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentActivityTab.test.tsx -t 'identity plane|truthful'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-5: Tab 5 deep-link navigation buttons route to scoped views" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentActivityTab.test.tsx -t 'deep-link'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-5: GET /api/agents/{id}/audit/stream fails closed with 404 for unknown agents" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_agent_audit_stream_returns_404_for_unknown_agent'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-5: GET /api/agents/{id}/audit/stream returns SSE stream for valid agent" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_agent_audit_stream_for_valid_agent'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-5: GET /api/audit preserves attributable identity plane metadata" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_audit_events_contain_attributable_identity_plane_metadata'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-5: GET /api/audit/stream is strictly side-effect free (zero SQL writes)" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_audit_stream_is_strictly_side_effect_free'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-6: URL deep-linking and secondary filters synchronize cleanly across Dossier tabs in Vitest" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/pages/AgentDetailPage.test.tsx -t 'deep-link|filter|tab'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-6: Secondary filters on /api/agents (lifecycle_state, spiffe_id) filter server-side in Pytest" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_get_agents_filter_by_lifecycle_state_and_spiffe_id'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p2-6: Secondary filters on /api/agents are strictly side-effect free under RFC 9110" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_get_agents_deep_link_filters_strictly_side_effect_free'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-1: Tab 5 renders correlated telemetry observations with layer and source filters" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentActivityTab.test.tsx -t 'correlated telemetry observations'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-1: GET /api/agents/{id}/telemetry supports pushdown filters (layer, source, limit)" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_agent_telemetry_pushdown_filters'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-1: GET /api/agents/{id}/telemetry is strictly side-effect free under RFC 9110" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_agent_telemetry_endpoint_side_effect_free'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-1: GET /api/agents/{id}/telemetry fails closed with 404 for unknown agent" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_agent_telemetry_unknown_agent_404'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-2: Tab 3 renders eBPF Sentinel ACK, drop counters, and probe states across containment tracks" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentAccessTab.test.tsx -t 'Sentinel ACK'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-2: GET /api/agents/{id} returns Sentinel kernel telemetry with ACK and containment probe state" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_agent_sentinel_containment_feedback_model'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-2: POST /api/agents/{id}/stun returns Sentinel ACK feedback and probe state" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_post_agent_stun_returns_sentinel_containment_feedback'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-2: GET /api/agents/{id} kernel telemetry endpoint is strictly side-effect free under RFC 9110" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_get_agent_detail_returns_sentinel_telemetry_side_effect_free'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-3: 15 mission acceptance criteria Vitest suite passes 100%" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/test/agentsAcceptanceCriteria.test.tsx"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-4: GET /api/agents/{id} returns origin and origin_verification side-effect free under RFC 9110" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_get_agent_detail_returns_origin_and_verification_side_effect_free'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-4: GET /api/agents/{id}/origin-verification returns OriginVerificationMetadata in Pytest" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_get_agent_origin_verification_endpoint_for_db_agent'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-4: GET /api/agents/{id}/origin-verification fails closed with 404 for unknown agent" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_get_agent_origin_verification_404_for_unknown_agent'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-4: GET /api/agents/{id}/origin-verification is strictly side-effect free under RFC 9110" {
  run bash -c "cd '${SRC_DIR}' && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -k 'test_get_agent_origin_verification_strictly_side_effect_free'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-4: Tab 2 Identity renders Live Authenticated Origin Verification panel and status in Vitest" {
  run bash -c "cd '${DASHBOARD_DIR}' && bunx vitest run src/components/AgentIdentityTab.test.tsx -t 'Live Authenticated Origin Verification'"
  [ "$status" -eq 0 ]
}

@test "sfagents-p3-4: database migration 034 exists and declares agent_origin_verifications table" {
  [ -f "${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src/db/migrations/034_agent_origin_verification.sql" ]
  run grep -E "CREATE TABLE IF NOT EXISTS public\.agent_origin_verifications" "${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src/db/migrations/034_agent_origin_verification.sql"
  [ "$status" -eq 0 ]
}


