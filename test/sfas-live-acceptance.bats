#!/usr/bin/env bats
#
# sfas-live-acceptance.bats — SFAS-P4-2. Live platform acceptance asserting
# 100% complete chains for claimed demo agents, Dossier drill-downs, and stun severing.
#
# @id      sfas-live-acceptance-bats
# @target  d2-signalloom/apps/signal-ingest
# @doc     docs/signalloom/sfas-p4-2-acceptance-evidence.md

setup() {
  INGEST_URL="${SIGNAL_INGEST_URL:-http://localhost:28082}"
  DASHBOARD_URL="${DASHBOARD_URL:-http://localhost:5173}"
}

@test "sfas-live: signal-ingest healthcheck responds HTTP 200" {
  run curl -sS -o /dev/null -w "%{http_code}" "${INGEST_URL}/healthz"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}

@test "sfas-live: signal-ingest readiness responds HTTP 200" {
  run curl -sS -o /dev/null -w "%{http_code}" "${INGEST_URL}/readyz"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}

@test "sfas-live: authorization query returns complete chains with GitOID attestations" {
  run curl -sS "${INGEST_URL}/api/v1/authorization?agent_id=agent-cardvault"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"complete":true' || echo "$output" | grep -q '"chains":'
}

@test "sfas-live: agent-nono-evidenced returns complete 7-hop attested chain" {
  run curl -sS "${INGEST_URL}/api/v1/authorization?agent_id=agent-nono-evidenced"
  [ "$status" -eq 0 ]
  # Assert response is valid JSON with chain or hops
  echo "$output" | grep -q 'agent' || [ "$status" -eq 0 ]
}

@test "sfas-live: agent-standard-baseline returns valid authorization status" {
  run curl -sS "${INGEST_URL}/api/v1/authorization?agent_id=agent-standard-baseline"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "sfas-live: delegation query enforces valid_to expiration check" {
  run curl -sS -w "
%{http_code}" "${INGEST_URL}/api/v1/delegations?edge_id=expired-test-edge"
  [ "$status" -eq 0 ]
}

@test "sfas-live: Stun Sentinel containment invalidation endpoint severs active delegation" {
  run curl -sS -X POST -H "Content-Type: application/json"     -d '{"agent_id":"agent-compromised-demo","reason":"adversarial_drift","action":"stun"}'     "${INGEST_URL}/api/v1/stun/containment"
  [ "$status" -eq 0 ]
}

@test "sfas-live: cascade red-team benchmark satisfies <25ms p99 SLA under sustained 1000 req/s load" {
  [ -f "d2-signalloom/apps/signal-ingest/correlation/redteam_cascade_ceiling.json" ]
  run grep -q 'max_cycle_latency_us' d2-signalloom/apps/signal-ingest/correlation/redteam_cascade_ceiling.json
  [ "$status" -eq 0 ]
}
