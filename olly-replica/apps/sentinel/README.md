# Olly Sentinel agent (Google ADK + A2A)

The runtime is Google ADK, the same runtime shape ARC (the firm's internal
AI-agent platform) manages in the client estate. Its agent-to-agent surface is
Google A2A, with the AgentCard as the declared identity, skills, and auth
contract. Read-only by construction: the pod has no ServiceNow endpoint, no
Elasticsearch credential, and no write scope anywhere.

## Structure

- `olly_sentinel/agent.py`: the ADK core. `SentinelPipelineAgent` (`BaseAgent`)
  runs the deterministic pipeline; the model never decides. When a model is
  configured, an ADK `LlmAgent` narrator writes the RCA text from session
  state, grounded on the correlated fault domain and leading error and told to
  treat every log line as a real production signal (never "synthetic" or a
  "replay"). Gemini/Vertex runs natively via ARC; anything else goes through
  LiteLLM to an OpenAI-compatible gateway such as Ollama. Runs go through an ADK
  `InMemoryRunner`, one session per correlation-ID. A module-level
  `root_agent = build_agent()` exposes the same object to `adk web` / `adk eval`
  without touching the Kafka or A2A paths.
- `olly_sentinel/a2a_server.py`: ADK's `to_a2a()` serves the committed
  AgentCard (`contracts/agent-card.olly-sentinel.v1.json`) at
  `/.well-known/agent-card.json` and the JSON-RPC `message/send` endpoint. The
  card is the single source of truth: identity, one skill
  (`triage_enrich_incident`), capabilities, and the EEMS bearer auth
  (`gco-sentinel-read`, read-only scopes). Served == committed is asserted in
  pytest and the cluster bats suite, so agent identity drift fails CI like
  payload drift.
- `olly_sentinel/main.py`: the Kafka consume loop (validate, triage
  Self-Healing-declined events only, dedup, loop guard, triage via the ADK
  runner, redacted contract-validated publish to `event_response`) and the A2A
  server share one runtime and one port. It consumes both source topics but acts
  only on `source: io_declined`, so the Mapping Service's subscription and
  automation-eligibility gates actually gate Olly.
  `message/send` is the TROUBLESHOOT action: same pipeline, direct invocation,
  returns the report, writes nothing (the bats suite proves no ticket is
  created for A2A requests).
- `olly_sentinel/pipeline.py`: MCP fan-out under EEMS scope checks with audit
  lines, deterministic fault-domain correlation over scrubbed evidence, payload
  assembly self-validated against the contract.
- Lifecycle metrics (`olly_incidents_*`, `olly_stage_duration_seconds`,
  `olly_hitl_pending`, `olly_llm_tokens_total`) feed the Eye in the Sky control
  tower via the ServiceMonitor.

## Evals

Two layers, both offline and reproducible against the seeded golden incidents.

- **The gate** (`tests/test_rca_signals.py`). Runs the full ADK pipeline against
  a hermetic evidence fixture (`tests/elk_stub.py`, which mirrors the seed) for
  all three managed apps and asserts: fault domain
  (`inventory-service` dependency, `payments-api` infrastructure,
  `customer-portal` application), confidence at or above 0.5, the evidence
  trajectory (exactly the three ELK patterns, each under `elk.logs.read`),
  per-app secret redaction, and no CHG inferred from log text. The agent is a
  `BaseAgent` and emits no ADK `tool_use`, so this evidence check is the
  trajectory guarantee, not `tool_trajectory_avg_score`. It runs in the image
  build.
- **The ADK Eval tab.** `rca_readiness.evalset.json`, `rca_readiness.test.json`,
  and `test_config.json` sit next to `agent.py`, so they appear in `adk web`'s
  Eval tab and run under `adk eval` and `AgentEvaluator` (`eval_test.py`). The
  response match is a loose ROUGE check; the hard assertions are the gate above.

```bash
make olly-eval        # signal-check gate + rca_readiness, offline (starts elk_stub)
make olly-adk-web     # adk web on :8000 with the Trace and Eval tabs; drives the
                      # elk_stub, or a port-forwarded elk-search-mcp via MCP_URL
```

Deterministic RCA (no `LLM_PROVIDER`) is the eval baseline; model credentials
are only needed for the optional LLM-judge metric. `olly_sentinel/.env.example`
documents the knobs. Runs accumulate under `olly_sentinel/.adk/` (gitignored).

## In-build tests

`tests/` runs during the image build (`apps/sentinel/Dockerfile`): contract
drift round-trips, redaction against the planted-secret corpus, the full ADK
pipeline with a canned MCP layer, the signal-check gate over all three
incidents, the served card vs the committed contract, and A2A `message/send`
(including malformed-request rejection). An image with drifted contracts or a
broken card cannot exist.

## Invoking the skill directly

```bash
kubectl -n olly-replica port-forward svc/olly-sentinel 8080 &
curl -s localhost:8080/.well-known/agent-card.json | jq .skills
curl -s -X POST localhost:8080/ -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": "1", "method": "message/send",
  "params": {"message": {"role": "user", "messageId": "m1",
    "parts": [{"kind": "text", "text": "{\"correlation_id\": \"my-corr-1\", \"app_id\": \"inventory-service\"}"}]}}
}' | jq .
```
