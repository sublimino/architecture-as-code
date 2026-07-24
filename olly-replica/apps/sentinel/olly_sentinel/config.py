"""Environment configuration. Names and defaults are shared with the manifests,
dashboard PromQL, and test suite."""

import os


def env(key: str, default: str = "") -> str:
    return os.getenv(key) or default


KAFKA_BROKERS = env("KAFKA_BROKERS", "redpanda.olly-replica.svc.cluster.local:9093")
CONSUME_TOPICS = [t.strip() for t in env("CONSUME_TOPICS", "netcool.io.events,netcool.io.events.declined").split(",") if t.strip()]
RESPONSE_TOPIC = env("RESPONSE_TOPIC", "ideas-172472-sn30.167564-impact.event_response")
# Observability-only topic carrying one record per gate the flow evaluates
# (pipeline-decision.v1). See decisions.py.
DECISIONS_TOPIC = env("DECISIONS_TOPIC", "olly.pipeline.decisions")
CONSUMER_GROUP = env("CONSUMER_GROUP", "olly-sentinel")

MCP_URL = env("MCP_URL", "http://elk-search-mcp:8080")
CONTRACTS_DIR = env("CONTRACTS_DIR", "/contracts")

EEMS_ROLE = env("EEMS_ROLE", "gco-sentinel-read")
# The read-only scope set for the full MCP fan-out. Every scope here is
# read-only by construction; the role holds no write entitlement anywhere.
# Removing a scope removes the tool from the fan-out at runtime, producing an
# entitlement denial.
_DEFAULT_SCOPES = ",".join([
    "elk.logs.read",
    "grafana.dashboards.read",
    "io.events.read",
    "cmdb.topology.read",
    "observr.traces.read",
    "drift.changes.read",
    "servicenow.incidents.read",
])
EEMS_SCOPES = {s.strip() for s in env("EEMS_SCOPES", _DEFAULT_SCOPES).split(",") if s.strip()}

# ARC identity chain (COIN M2M token exchange -> PlainID PDP -> EEMS PIP ->
# AuthZ-CTX across the Olly -> Orbit A2A hop), served in-cluster by olly-authz.
# Olly mints an M2M-enhanced token on-behalf-of a human ACME id (OBO: the human
# stays the subject, the agent is the actor) and carries the bearer on every MCP
# call and the AuthZ-CTX on the A2A hop. One authz_ctx_id anchors the audit.
AUTHZ_ENABLED = env("AUTHZ_ENABLED", "true") == "true"
COIN_URL = env("COIN_URL", "http://olly-authz:8001").rstrip("/")
AUTHZ_ACME_ID = env("AUTHZ_ACME_ID", "e12345")            # human on-behalf-of whom Olly runs
AUTHZ_AGENT = env("AUTHZ_AGENT", "olly-sentinel")
ORBIT_AGENT = env("ORBIT_AGENT", "orbit")
AUTHZ_JWT_SECRET = env("AUTHZ_JWT_SECRET", "acme-co-authz-dev-secret")
AUTHZ_TOKEN_TTL = int(env("AUTHZ_TOKEN_TTL", "300"))
# Static-token escape hatch, mirroring the client's MCP_STATIC_TOKEN: a
# pre-issued bearer that bypasses the COIN exchange. Empty by default (mint).
MCP_STATIC_TOKEN = env("MCP_STATIC_TOKEN", "")
# The actions Olly requests: the seven read-only MCP scopes plus the higher-level
# actions the A2A hop reasons about (restart delegation, narrowed at Orbit).
AUTHZ_REQUESTED_ACTIONS = [a.strip() for a in env(
    "AUTHZ_REQUESTED_ACTIONS",
    ",".join(sorted(EEMS_SCOPES) + ["troubleshoot", "restart_service"]),
).split(",") if a.strip()]

# Orbit's local grants for the A2A narrow-only intersection: the receiving agent
# narrows the inbound AuthZ-CTX by its own grant (never widens). Mirrors
# olly-authz AGENT_LOCAL_GRANTS["orbit"] - read scopes + troubleshoot, with the
# mutating action capped tighter than Olly (restart_service 3 -> 1).
ORBIT_LOCAL_GRANT = {**{s: 1 for s in EEMS_SCOPES}, "troubleshoot": 10, "restart_service": 1}

# LLM narrator. The pipeline is deterministic; the model only writes the RCA
# narrative (invariant 8: the model narrates and the pipeline decides). Provider is
# one of openrouter | anthropic | openai | ollama | gemini, or empty for the
# deterministic RCA. Cloud providers need LLM_API_KEY; without it the agent
# stays deterministic (so it runs before keys are added). Keys/model come from
# the olly-llm secret, populated from .env by `make olly-llm-secret`.
LLM_PROVIDER = env("LLM_PROVIDER").lower()  # empty => deterministic (or inferred from LLM_URL/gemini below)
LLM_MODEL = env("LLM_MODEL")                # provider-specific model id
LLM_API_KEY = env("LLM_API_KEY")            # openrouter/anthropic/openai
LLM_URL = env("LLM_URL")                    # ollama / custom OpenAI-compatible base
LLM_TEMPERATURE = float(env("LLM_TEMPERATURE", "0.2"))

HITL_ENABLED = env("HITL_ENABLED", "false") == "true"
HITL_THRESHOLD = 0.5

# Orbit: the action sub-agent. When enabled, a parked enrichment gets an
# action proposal that a human approves with a signed token before a stubbed
# executor records it. The sentinel loads only the PUBLIC approval key. It
# cannot mint an approval, so it cannot approve its own proposals.
ORBIT_ENABLED = env("ORBIT_ENABLED", "false") == "true"
APPROVAL_PUBKEY_FILE = env("APPROVAL_PUBKEY_FILE", "/var/run/olly/orbit-approval-pub.pem")

AGENT_VERSION = env("AGENT_VERSION", "dev")
EVAL_RUN_ID = env("EVAL_RUN_ID", "local-dev")

LISTEN_PORT = int(env("LISTEN_PORT", "8080"))

# Orbit's own A2A endpoint, served on a second port so a peer or authorized user
# can invoke propose_action and get back an A2A input-required task (the native
# HITL pause) that the signed approval resolves. Requires a model; skipped when
# none is configured. The card at /.well-known/agent-card.json advertises it.
ORBIT_A2A_PORT = int(env("ORBIT_A2A_PORT", "8081"))

# LLM Guard: the model-based scanner on the Olly -> Orbit A2A hop (Security
# Sandbox). Defence in depth behind the deterministic redactor. Off by default;
# when enabled, Olly scans the message it is about to send to Orbit
# (/analyze/prompt) and Orbit's reply (/analyze/output), and a tripped scan
# holds the hand-off. The redactor is the hard control and always runs; the
# guard is a second opinion, so a guard outage does not block the pipeline.
LLM_GUARD_ENABLED = env("LLM_GUARD_ENABLED", "false") == "true"
LLM_GUARD_URL = env("LLM_GUARD_URL", "http://llm-guard.olly-replica.svc.cluster.local:8000").rstrip("/")
LLM_GUARD_TOKEN = env("LLM_GUARD_TOKEN", "llm-guard-token")
LLM_GUARD_TIMEOUT = float(env("LLM_GUARD_TIMEOUT", "30"))

MAX_ENRICHMENT_PASSES = 1
QUERY_WINDOW_MINUTES = 240
