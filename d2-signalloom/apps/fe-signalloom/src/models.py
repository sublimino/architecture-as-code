"""Domain models, contracts, and validation helpers for Discovery and Agent Governance.

Provides:
1. SPIFFE ID validation (scheme, trust domain, path, and tenant isolation).
2. Discovery claim request and response models with strict input validation.
3. Agent lifecycle state machine contracts and transition validation.
4. Structured error envelopes matching Signal Loom platform API doctrine.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Annotated, Any, Literal
from urllib.parse import urlparse

from pydantic import BaseModel, ConfigDict, Field, field_validator


# ---------------------------------------------------------------------------
# Error Envelope Models
# ---------------------------------------------------------------------------

class ErrorDetail(BaseModel):
    model_config = ConfigDict(extra="forbid")
    code: str
    message: str


class ErrorResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")
    error: ErrorDetail


# ---------------------------------------------------------------------------
# SPIFFE ID Validation
# ---------------------------------------------------------------------------

DEFAULT_SPIFFE_TRUST_DOMAIN = "cluster.local"

# RFC 1123 DNS label regex for trust domains and namespaces
DNS_LABEL_REGEX = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")

# Valid SPIFFE path segment regex (alphanumeric, hyphens, underscores, dots)
SEGMENT_REGEX = re.compile(r"^[a-zA-Z0-9._-]+$")


def validate_spiffe_id(
    spiffe_id: str | None,
    expected_tenant_id: str | None = None,
) -> tuple[bool, str | None]:
    """Validate SPIFFE ID format, scheme, trust domain, and tenant isolation.

    Returns:
        (is_valid, error_message)
    """
    if not spiffe_id or not isinstance(spiffe_id, str):
        return False, "SPIFFE ID cannot be empty"

    cleaned = spiffe_id.strip()
    if not cleaned:
        return False, "SPIFFE ID cannot be empty or whitespace"

    if not cleaned.startswith("spiffe://"):
        return False, "Invalid SPIFFE ID scheme: scheme must be 'spiffe://'"

    try:
        parsed = urlparse(cleaned)
    except Exception as exc:
        return False, f"Malformed SPIFFE ID: {exc}"

    if parsed.scheme != "spiffe":
        return False, "Invalid SPIFFE ID scheme: scheme must be 'spiffe://'"

    if not parsed.netloc:
        return False, "Malformed SPIFFE ID: trust domain is missing"

    if ":" in parsed.netloc:
        return False, "Malformed SPIFFE ID: port numbers in trust domain are prohibited"

    if "//" in parsed.path:
        return False, "Malformed SPIFFE ID: path contains empty segments"

    clean_path = parsed.path.strip("/")
    if not clean_path:
        return False, "Malformed SPIFFE ID: path is empty"

    if parsed.query or parsed.fragment:
        return False, "Malformed SPIFFE ID: query strings and fragments are prohibited"

    segments = clean_path.split("/")
    for seg in segments:
        if not SEGMENT_REGEX.match(seg):
            return False, f"Malformed SPIFFE ID: invalid segment '{seg}'"

    # Tenant boundary enforcement: detect cross-tenant spoofing
    if expected_tenant_id:
        # Check /tenant/<id>/ segment
        tenant_match = re.search(r"/tenant/([^/]+)", parsed.path)
        if tenant_match:
            tenant_in_spiffe = tenant_match.group(1)
            if tenant_in_spiffe != expected_tenant_id:
                return (
                    False,
                    f"Cross-tenant SPIFFE ID forbidden: ID bound to '{tenant_in_spiffe}', but caller is '{expected_tenant_id}'",
                )

        # Check /ns/<namespace>/ segment
        ns_match = re.search(r"/ns/([^/]+)", parsed.path)
        if ns_match:
            ns_in_spiffe = ns_match.group(1)
            if ns_in_spiffe.startswith("tenant-") and ns_in_spiffe != f"tenant-{expected_tenant_id}":
                return (
                    False,
                    f"Cross-tenant SPIFFE ID forbidden: namespace '{ns_in_spiffe}' belongs to another tenant",
                )

    return True, None


def format_spiffe_id(
    tenant_id: str,
    agent_id: str,
    trust_domain: str = DEFAULT_SPIFFE_TRUST_DOMAIN,
) -> str:
    """Format canonical Signal Loom SPIFFE ID."""
    return f"spiffe://{trust_domain}/platform/signalloom/tenant/{tenant_id}/agent/{agent_id}"


# ---------------------------------------------------------------------------
# Namespace Validation
# ---------------------------------------------------------------------------

KNOWN_NAMESPACES = frozenset({
    "fe-signalloom-agents",
    "staging-workloads",
    "identity-entra",
    "gcp-europe-west1",
    "agent-swarm",
    "default",
    "kube-system",
    "inf-bao",
})


def is_valid_namespace_format(namespace: str) -> bool:
    """Validate RFC 1123 Kubernetes namespace format."""
    if not namespace or len(namespace) > 63:
        return False
    return bool(DNS_LABEL_REGEX.match(namespace))


def is_known_or_tenant_namespace(namespace: str, tenant_id: str | None = None) -> bool:
    """Check if namespace exists or matches tenant pattern."""
    if namespace in KNOWN_NAMESPACES:
        return True
    if namespace.startswith("tenant-"):
        if tenant_id and namespace == f"tenant-{tenant_id}":
            return True
        return True
    if namespace.startswith("agent-") or namespace.startswith("demo-"):
        return True
    return False


# ---------------------------------------------------------------------------
# Discovery Claim Contracts
# ---------------------------------------------------------------------------

class DiscoveryClaimRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str = Field(..., description="Unique agent or workload identifier")
    namespace: str = Field(..., description="Kubernetes namespace containing the workload")
    token_budget_limit: int = Field(default=100000, ge=1)
    spiffe_id: str | None = Field(default=None, description="Optional client-asserted SPIFFE identity")
    metadata: dict[str, Any] = Field(default_factory=dict)

    @field_validator("agent_id")
    @classmethod
    def validate_agent_id(cls, v: str) -> str:
        cleaned = v.strip()
        if not cleaned:
            raise ValueError("agent_id must not be empty or whitespace")
        return cleaned

    @field_validator("namespace")
    @classmethod
    def validate_namespace(cls, v: str) -> str:
        cleaned = v.strip()
        if not cleaned:
            raise ValueError("namespace must not be empty or whitespace")
        if not is_valid_namespace_format(cleaned):
            raise ValueError(f"Invalid namespace format: '{cleaned}' must be a valid RFC 1123 DNS label")
        return cleaned


class DiscoveryClaimResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    claim_id: str
    tenant_id: str
    agent_id: str
    namespace: str
    spiffe_id: str
    status: Literal["granted", "governed"] = "granted"
    claimed_at: str
    allocated_token_budget: int = 100000


# ---------------------------------------------------------------------------
# Agent Lifecycle State Machine
# ---------------------------------------------------------------------------

# Canonical 3-stage governance lifecycle: Governed, Suspended, Revoked
VALID_CANONICAL_STATES: frozenset[str] = frozenset({
    "Governed",
    "Suspended",
    "Revoked",
})

VALID_INTERNAL_STATES: frozenset[str] = frozenset({
    "discovered",
    "registered",
    "enrolled",
    "active",
    "governed",
    "suspended",
    "stunned",
    "revoked",
    "decommissioned",
})

# Complete transition graph
# Keys are from-states; values are reachable to-states.
# Terminal states have an empty set.
LIFECYCLE_TRANSITIONS: dict[str, frozenset[str]] = {
    "discovered": frozenset({"governed", "active", "registered", "enrolled", "in_review", "ignored"}),
    "registered": frozenset({"enrolled", "active", "governed", "suspended", "stunned", "revoked", "decommissioned"}),
    "enrolled":   frozenset({"active", "governed", "suspended", "stunned", "revoked", "decommissioned"}),
    "active":     frozenset({"governed", "suspended", "stunned", "revoked", "decommissioned"}),
    "governed":   frozenset({"suspended", "stunned", "revoked", "decommissioned"}),
    "suspended":  frozenset({"governed", "active", "revoked", "decommissioned"}),
    "stunned":    frozenset({"governed", "active", "suspended", "revoked", "decommissioned"}),
    # Terminal states: no outbound transitions
    "revoked":        frozenset(),
    "decommissioned": frozenset(),
}


def canonicalize_lifecycle_state(raw_state: str | None) -> str:
    """Map any raw state to the canonical 3-stage governance lifecycle."""
    if not raw_state:
        return "Governed"
    s = raw_state.strip().lower()
    if s in {"revoked", "decommissioned", "terminated"}:
        return "Revoked"
    if s in {"suspended", "stunned", "frozen"}:
        return "Suspended"
    return "Governed"


def validate_lifecycle_transition(from_state: str, to_state: str) -> None:
    """Validate lifecycle transition rules.

    Raises:
        ValueError (maps to 400 Bad Request) if to_state is not recognized.
        RuntimeError (maps to 409 Conflict) if the transition is illegal or from a terminal state.
    """
    to_clean = to_state.strip().lower()
    from_clean = from_state.strip().lower()

    if to_clean not in VALID_INTERNAL_STATES and to_state not in VALID_CANONICAL_STATES:
        raise ValueError(
            f"'{to_state}' is not a valid lifecycle state. "
            f"Valid states: {', '.join(sorted(VALID_INTERNAL_STATES))}"
        )

    # Normalize canonical input to internal
    if to_clean == "governed":
        to_target = "governed"
    else:
        to_target = to_clean

    allowed = LIFECYCLE_TRANSITIONS.get(from_clean)
    if allowed is None:
        # Unknown from-state defaults to registered
        allowed = LIFECYCLE_TRANSITIONS["registered"]

    if to_target not in allowed and to_clean not in allowed:
        raise RuntimeError(
            f"Cannot transition from '{from_state}' to '{to_state}'. "
            f"Valid targets from '{from_state}': "
            f"{', '.join(sorted(allowed)) if allowed else '(terminal state - no transitions)'}"
        )


class AgentTransitionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    to_state: str
    reason: str
    spiffe_id: str | None = None


class AgentTransitionResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    agent_id: str
    from_state: str
    to_state: str
    actor: str
    reason: str
    timestamp: str


# ---------------------------------------------------------------------------
# Attention Evaluation Helper
# ---------------------------------------------------------------------------

def evaluate_agent_attention(
    compliance_failing: int = 0,
    compliance_pending: int = 0,
    findings_count: int = 0,
    has_sbom: bool = True,
    svid_expired: bool = False,
    lifecycle_state: str = "governed",
    posture_score: float | None = 83.0,
) -> tuple[Literal["critical", "warning", "info", "none"], str | None, bool]:
    """Determine attention level, highest issue, and whether attention is required.

    Returns:
        (level, highest_issue, requires_attention)
    """
    state_lower = lifecycle_state.strip().lower()

    if svid_expired:
        return "critical", "SVID cryptographic credential expired", True

    if compliance_failing > 0 or findings_count > 0:
        count = compliance_failing or findings_count
        return "critical", f"{count} security finding(s) detected", True

    if state_lower in {"suspended", "stunned", "revoked", "decommissioned"}:
        return "critical", f"Agent lifecycle is {lifecycle_state}", True

    if not has_sbom:
        return "warning", "Missing machine-readable SBOM supply chain attestation", True

    if compliance_pending > 0:
        return "warning", f"{compliance_pending} control assessment(s) pending", True

    if posture_score is not None:
        normalized = posture_score * 100 if posture_score <= 1.0 else posture_score
        if normalized < 50.0:
            return "warning", f"Compliance posture score ({normalized:.0f}%) below threshold", True

    return "none", None, False
