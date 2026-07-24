"""Ports, the signing secret, and the entitlement data for the in-cluster ARC
identity chain (COIN token exchange -> PlainID PDP -> EEMS PIP -> AuthZ-CTX
across the Olly -> Orbit A2A hop).

The action vocabulary is unified so one token drives the whole flow: the seven
read-only MCP scopes Olly's fan-out needs *and* the higher-level actions Orbit
reasons about (troubleshoot, restart_service). elk-search-mcp checks the read
scope; the A2A hop narrows the actions.
"""

import os

# HS256 shared secret for the tokens. Injected from the olly-authz secret in the
# cluster; every verifier (elk-search-mcp, Orbit) holds the same secret.
JWT_SECRET = os.getenv("AUTHZ_JWT_SECRET", "acme-co-authz-dev-secret")
JWT_TTL = int(os.getenv("AUTHZ_JWT_TTL", "300"))

# Service ports.
COIN_PORT = int(os.getenv("COIN_PORT", "8001"))     # COIN JWT Issuer
PDP_PORT = int(os.getenv("PDP_PORT", "8002"))       # PlainID PDP
EEMS_PORT = int(os.getenv("EEMS_PORT", "8003"))     # EEMS PIP REST

# The three services are co-located in one pod: bind on all interfaces so peers
# reach the Service, but the COIN->PDP->EEMS internal calls stay on loopback.
BIND_HOST = os.getenv("AUTHZ_BIND_HOST", "0.0.0.0")
CONNECT_HOST = os.getenv("AUTHZ_CONNECT_HOST", "127.0.0.1")


def url(port: int) -> str:
    return f"http://{CONNECT_HOST}:{port}"


# Audit log (the Jarvis stand-in). One JSONL record per authorization decision,
# all records for one request linked by authz_ctx_id.
AUDIT_LOG = os.getenv("AUTHZ_AUDIT_LOG", "/tmp/acme-authz-audit.jsonl")

# The read-only MCP scopes, one per tool in Olly's fan-out. Granting a scope
# with a positive limit means "allowed"; elk-search-mcp checks membership.
READ_SCOPES = (
    "elk.logs.read",
    "grafana.dashboards.read",
    "io.events.read",
    "cmdb.topology.read",
    "observr.traces.read",
    "drift.changes.read",
    "servicenow.incidents.read",
)

# The higher-level, potentially-mutating actions the A2A hop reasons about.
HIGH_ACTIONS = ("troubleshoot", "restart_service", "close_incident")

# The full closed action set the chain evaluates.
ACTIONS = READ_SCOPES + HIGH_ACTIONS


def _read_all(limit: int = 1) -> dict:
    return {s: limit for s in READ_SCOPES}


# EEMS entitlement source of truth (the "system of record" the PIP reads).
# has_<action>_access and max_<action>_limit are derived from this per user.
ENTITLEMENTS = {
    # SRE on-call: read everything, may delegate a bounded restart. Olly runs
    # on-behalf-of this identity by default (OBO).
    "e12345": {
        "grants": {**_read_all(), "troubleshoot": 10, "restart_service": 3},
        "gp_numbers": ["GP-100"],
        "approved_domains": ["acme-co.internal"],
    },
    # Read-only analyst: investigate only, no mutating action to delegate.
    "e99999": {
        "grants": {**_read_all(), "troubleshoot": 10},
        "gp_numbers": ["GP-200"],
        "approved_domains": ["acme-co.internal"],
    },
}

# Per-agent local grants. The A2A hop intersects the inbound AuthZ-CTX with the
# receiving agent's local grant and can only narrow (drop an action or lower a
# limit), never widen. Orbit caps the mutating action tighter than Olly, which
# the dashboard makes visible.
AGENT_LOCAL_GRANTS = {
    "olly-sentinel": {**_read_all(), "troubleshoot": 10, "restart_service": 3},
    "orbit": {**_read_all(), "troubleshoot": 10, "restart_service": 1},
}
