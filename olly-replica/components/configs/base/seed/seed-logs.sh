#!/bin/sh
# Seed the replica's Elasticsearch with synthetic logs across the three
# index patterns the client design allows (app-logs-*, infra-logs-*,
# audit-logs-*), plus the injection corpus and the planted fake secrets and
# PII (loaded from injection-corpus.ndjson) the safety suite tests against.
# Idempotent enough for re-runs: data streams are append-only and each run
# tags its docs with a run id.
set -eu

ES="${ES_URL:-http://olly-es-http:9200}"
CURL="curl -fsS -u elastic:${ELASTIC_PASSWORD}"

i=0
until ${CURL} "${ES}/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "${i}" -gt 120 ]; then
    echo "elasticsearch never became reachable" >&2
    exit 1
  fi
  echo "waiting for elasticsearch (${i}/120)"
  sleep 5
done

echo "creating index templates for the three data stream patterns"
for pattern in app-logs infra-logs audit-logs; do
  ${CURL} -X PUT "${ES}/_index_template/${pattern}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"index_patterns\": [\"${pattern}-*\"],
      \"data_stream\": {},
      \"priority\": 200,
      \"template\": {
        \"settings\": { \"number_of_replicas\": 0 },
        \"mappings\": {
          \"properties\": {
            \"@timestamp\": { \"type\": \"date\" },
            \"app_id\": { \"type\": \"keyword\" },
            \"level\": { \"type\": \"keyword\" },
            \"message\": { \"type\": \"text\" },
            \"olly\": {
              \"properties\": {
                \"seed\": { \"type\": \"keyword\" },
                \"case_id\": { \"type\": \"keyword\" }
              }
            }
          }
        }
      }
    }" >/dev/null
done

# The trace emitter in the tenant apps owns its own index template for its
# traces-synthetic index (ensureTraceIndex), which already pins
# number_of_replicas to 0 so the single-node cluster stays green. We do NOT
# create a composable traces-* template here: it collides with the emitter's
# traces-synthetic template at the same priority (ES rejects it with a 400,
# which used to crash-loop this seed job). Instead just defensively pin
# replicas on any traces index that already exists (best-effort, never fatal).
${CURL} -X PUT "${ES}/traces-*/_settings" \
  -H 'Content-Type: application/json' \
  -d '{ "index": { "number_of_replicas": 0 } }' >/dev/null 2>&1 || true

echo "creating the seed timestamp ingest pipeline"
${CURL} -X PUT "${ES}/_ingest/pipeline/olly-seed-ts" \
  -H 'Content-Type: application/json' \
  -d '{
    "description": "Stamp seeded docs at ingest time so dashboards see recent data",
    "processors": [
      { "set": { "field": "@timestamp", "value": "{{_ingest.timestamp}}", "override": true } }
    ]
  }' >/dev/null

RUN_ID="seed-$(date -u +%Y%m%d%H%M%S)"
BULK=/tmp/bulk.ndjson
: >"${BULK}"

emit() { # stream app level message
  printf '{"create":{"_index":"%s"}}\n' "$1" >>"${BULK}"
  printf '{"app_id":"%s","level":"%s","message":"%s","olly":{"seed":"%s"}}\n' \
    "$2" "$3" "$4" "${RUN_ID}" >>"${BULK}"
}

echo "generating synthetic logs"
# Steady-state noise for the estate view.
for app in inventory-service payments-api customer-portal; do
  n=0
  while [ "${n}" -lt 8 ]; do
    emit app-logs-synthetic "${app}" INFO "request completed path=/api/v1/items status=200 duration_ms=$((20 + n * 3))"
    n=$((n + 1))
  done
  emit infra-logs-synthetic "${app}" INFO "pod healthy: liveness and readiness probes passing"
  emit audit-logs-synthetic "${app}" INFO "auth ok: service account token accepted for read scope"
done

# --- Seeded incidents -------------------------------------------------------
# Three realistic failure bursts, one per managed app, each landing in a
# distinct fault domain so the demo shows Olly telling them apart. The RCA is
# decided deterministically from the dominant ERROR signal (see pipeline.py);
# the LLM only narrates. Each scenario carries the surrounding WARN/INFO
# context an SRE would actually correlate, framed for a financial-services
# estate (ledgers, settlement, the customer banking portal).

# Incident 1 -- inventory-service: DEPENDENCY.
# The positions/stock ledger DB slows down, the connection pool drains, and
# requests time out waiting for a connection. IO self-healing declines the
# replica bump, making the event Olly-eligible. Expected fault domain:
# dependency (pool/timeout/upstream/connection keywords dominate).
n=0
while [ "${n}" -lt 12 ]; do
  emit app-logs-synthetic inventory-service ERROR "db connection pool exhausted: timeout acquiring connection to positions-ledger-db after 5000ms (pool size 20, waiters $((30 + n)))"
  n=$((n + 1))
done
emit app-logs-synthetic inventory-service ERROR "upstream call to positions-ledger-db failed: connection reset by peer during ledger revaluation"
emit app-logs-synthetic inventory-service WARN "upstream latency to positions-ledger-db p99=4800ms, circuit breaker half-open"
emit app-logs-synthetic inventory-service WARN "stock-position reconciliation deferred: no healthy connection available in pool"
emit infra-logs-synthetic inventory-service INFO "hpa scaled inventory-service 3 -> 6 replicas (cpu target breached)"
emit audit-logs-synthetic inventory-service INFO "config change applied: connection_pool.max=20 (was 50) actor=deploy-pipeline change=CHG0044821"

# Incident 2 -- payments-api: INFRASTRUCTURE.
# The end-of-day settlement workers were given a memory limit below their
# working set and get OOMKilled mid-batch, crash-looping and stalling
# settlement. Expected fault domain: infrastructure (oom/restart/node
# keywords dominate); no dependency keywords appear in these ERROR lines.
n=0
while [ "${n}" -lt 11 ]; do
  emit app-logs-synthetic payments-api ERROR "settlement worker OOMKilled mid EOD batch: oom_kill=true, memory limit 512Mi exceeded (rss=548Mi) batch=$((900000 + n))"
  n=$((n + 1))
done
emit infra-logs-synthetic payments-api ERROR "container settlement-worker restarted 6 times in 8m, last state=OOMKilled exit_code=137"
emit infra-logs-synthetic payments-api WARN "node ip-10-0-3-14 under MemoryPressure=true, pod payments-api-settlement evicted"
emit app-logs-synthetic payments-api WARN "EOD settlement batch stalled: 3200 of 41000 payment instructions committed before worker crash"
emit audit-logs-synthetic payments-api INFO "config change applied: settlement.worker.memory_limit=512Mi (was 1Gi) actor=deploy-pipeline change=CHG0044907"

# Incident 3 -- customer-portal: APPLICATION.
# A bad release ships a code path that dereferences a null account object,
# throwing on the authenticated account-summary view and returning 500s to
# signed-in banking customers. Expected fault domain: application (no
# dependency/infrastructure keywords in these ERROR lines).
n=0
while [ "${n}" -lt 11 ]; do
  emit app-logs-synthetic customer-portal ERROR "unhandled NullPointerException in AccountSummaryController.render: account object was null for authenticated session (build v2.4.1)"
  n=$((n + 1))
done
emit app-logs-synthetic customer-portal ERROR "HTTP 500 serving GET /portal/accounts/summary for signed-in customer (build v2.4.1)"
emit app-logs-synthetic customer-portal WARN "error rate 42% on /portal/accounts/summary since release v2.4.1, breaching 1% SLO"
emit infra-logs-synthetic customer-portal INFO "readiness probe passing: process healthy, fault is in request handling not the pod"
emit audit-logs-synthetic customer-portal INFO "deployment event: customer-portal rolled out v2.4.1 actor=deploy-pipeline change=CHG0044933"

# --- HITL / A2A scenarios ---------------------------------------------------
# Three more restart-addressable infrastructure incidents so the demo can show
# the Orbit hand-off (HITL + A2A) on more than one app. Each is an OOM/restart
# loop: the ERROR lines carry oom/restart signatures and no dependency keywords,
# so the RCA lands in the infrastructure domain and Orbit proposes
# remediate_restart_service, which parks the enrichment for human approval and
# drives the Olly -> Orbit A2A hand-off (COIN M2M + AuthZ-CTX, restart 3 -> 1).
# Each carries an approved change (change=CHG...) so drift does not promote the
# fault to the change domain. Trigger any of them with:
#   make replay APP=fx-pricing-engine   (or card-auth-gateway | statement-generator)

# Incident 4 -- fx-pricing-engine: INFRASTRUCTURE.
# Market-open pricing workers were handed a heap limit below their snapshot
# working set and get OOMKilled, crash-looping so FX rates stop publishing.
n=0
while [ "${n}" -lt 11 ]; do
  emit app-logs-synthetic fx-pricing-engine ERROR "pricing worker OOMKilled during market-open snapshot: oom_kill=true, java heap 2Gi exhausted, worker restarting (snapshot=$((70000 + n)))"
  n=$((n + 1))
done
emit infra-logs-synthetic fx-pricing-engine ERROR "container fx-pricing-worker restarted 5 times in 6m, last state=OOMKilled exit_code=137"
emit infra-logs-synthetic fx-pricing-engine WARN "node ip-10-0-5-22 under MemoryPressure=true, pod fx-pricing-engine evicted"
emit app-logs-synthetic fx-pricing-engine WARN "fx rate publish delayed: pricing snapshot incomplete after worker crash"
emit audit-logs-synthetic fx-pricing-engine INFO "config change applied: fx-pricing.heap_limit=2Gi (was 4Gi) actor=deploy-pipeline change=CHG0045012"

# Incident 5 -- card-auth-gateway: INFRASTRUCTURE.
# The card authorization workers were capped below their peak working set and
# OOMKill under an authorization spike, landing in CrashLoopBackOff so card
# approvals degrade for signed-in customers at the point of sale.
n=0
while [ "${n}" -lt 11 ]; do
  emit app-logs-synthetic card-auth-gateway ERROR "authorization worker OOMKilled and restarting during card-auth spike: memory limit 768Mi exceeded (rss=812Mi) auth_batch=$((5000 + n))"
  n=$((n + 1))
done
emit infra-logs-synthetic card-auth-gateway ERROR "container card-auth-gateway in CrashLoopBackOff: restarted 9 times in 12m, last state=OOMKilled exit_code=137"
emit infra-logs-synthetic card-auth-gateway WARN "node ip-10-0-2-9 under MemoryPressure=true, pods on the node being evicted"
emit app-logs-synthetic card-auth-gateway WARN "card authorization approvals degraded: 6 percent of auth requests failing while the worker restarts"
emit audit-logs-synthetic card-auth-gateway INFO "config change applied: card-auth.worker.memory_limit=768Mi (was 1536Mi) actor=deploy-pipeline change=CHG0045044"

# Incident 6 -- statement-generator: INFRASTRUCTURE.
# The monthly statement batch renders large PDFs and was given a memory limit
# below its working set, so the worker is OOMKilled mid-run and restarts in a
# loop, stalling statement delivery.
n=0
while [ "${n}" -lt 11 ]; do
  emit app-logs-synthetic statement-generator ERROR "statement batch worker OOMKilled rendering monthly PDFs: oom_kill=true, memory limit 1Gi exceeded (rss=1.1Gi), worker restarting (batch=$((30000 + n)))"
  n=$((n + 1))
done
emit infra-logs-synthetic statement-generator ERROR "container statement-worker restarted 7 times in 10m, last state=OOMKilled exit_code=137"
emit infra-logs-synthetic statement-generator WARN "node ip-10-0-7-3 under MemoryPressure=true, statement-generator pod evicted mid-run"
emit app-logs-synthetic statement-generator WARN "monthly statement generation stalled: 12000 of 240000 statements rendered before the worker crash"
emit audit-logs-synthetic statement-generator INFO "config change applied: statement.worker.memory_limit=1Gi (was 2Gi) actor=deploy-pipeline change=CHG0045077"

echo "loading generated docs"
${CURL} -X POST "${ES}/_bulk?pipeline=olly-seed-ts" \
  -H 'Content-Type: application/x-ndjson' \
  --data-binary "@${BULK}" | grep -q '"errors":false'

echo "loading the injection corpus and planted secrets"
${CURL} -X POST "${ES}/_bulk?pipeline=olly-seed-ts" \
  -H 'Content-Type: application/x-ndjson' \
  --data-binary "@/seed/injection-corpus.ndjson" | grep -q '"errors":false'

echo "seed complete: run ${RUN_ID}"
