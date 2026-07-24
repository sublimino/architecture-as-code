"""Approval verification and the parked-proposal store.

This is the trust boundary for the strategic decision (Olly as a component with
TROUBLESHOOT / REMEDIATE actions): an action only leaves ``proposed`` when a
human approval is presented, and the approval is an ed25519-signed JWT that
**this process cannot mint**. The sentinel loads only the PUBLIC key; the
private half lives with the broker's approve endpoint. Because the sentinel
holds only the public half, it cannot sign its own approval and bypass the gate.

The verification is strict and binds the token to one proposal:

  * signature must verify against the pinned public key (EdDSA only),
  * ``aud`` must be this agent, ``iss`` must be the approval service,
  * ``exp`` must be in the future, ``iat``/``nbf`` sane,
  * ``sub`` (the proposal_id), ``correlation_id`` and ``action`` claims must
    equal the proposal being approved, binding each token to a single proposal.

``joserfc`` is already in the image (authlib -> google-adk),
and ``cryptography`` provides the Ed25519 primitives it wraps.
"""

import logging
import os
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

from . import config

log = logging.getLogger("olly-sentinel")

AUDIENCE = "olly-sentinel"
ISSUER = "estate95-approval"
ALGORITHMS = ["EdDSA"]


class ApprovalError(Exception):
    """Raised when an approval token is missing, malformed, expired, forged,
    or bound to a different proposal. Always denies."""


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Proposal:
    """One action proposal parked for human approval (action-proposal.v1 in
    memory). It advances past ``proposed`` only with a verified token."""
    proposal_id: str
    correlation_id: str
    app_id: str
    action: str
    justification: str
    evidence_refs: list[str] = field(default_factory=list)
    state: str = "proposed"
    approved_by: str = ""
    decided_at: str = ""
    created_at: str = field(default_factory=_now)
    # The enrichment held back pending approval, republished verbatim on
    # approval so the human approves exactly what the agent proposed.
    enrichment: dict = field(default_factory=dict)

    def to_contract(self) -> dict:
        """Render as an action-proposal.v1 payload."""
        approval: dict = {"state": self.state}
        if self.approved_by:
            approval["approved_by"] = self.approved_by
        if self.decided_at:
            approval["decided_at"] = self.decided_at
        payload = {
            "schema_version": "v1",
            "proposal_id": self.proposal_id,
            "correlation_id": self.correlation_id,
            "app_id": self.app_id,
            "action": self.action,
            "justification": self.justification[:2000],
            "approval": approval,
        }
        if self.evidence_refs:
            payload["evidence_refs"] = self.evidence_refs[:8]
        return payload

    def public_view(self) -> dict:
        """What the console shows: the contract plus a little context, minus
        the full enrichment (available via the incidents surface)."""
        v = self.to_contract()
        v["created_at"] = self.created_at
        v["confidence_score"] = self.enrichment.get("rca", {}).get("confidence_score")
        v["fault_domain"] = self.enrichment.get("rca", {}).get("fault_domain")
        return v


class ProposalStore:
    """Thread-safe registry of parked proposals. The Kafka consumer parks; the
    HTTP approve/reject handlers resolve; both touch it under one lock."""

    def __init__(self) -> None:
        self._mu = threading.Lock()
        self._by_id: dict[str, Proposal] = {}

    def add(self, p: Proposal) -> None:
        with self._mu:
            self._by_id[p.proposal_id] = p

    def get(self, proposal_id: str) -> Proposal | None:
        with self._mu:
            return self._by_id.get(proposal_id)

    def list(self, state: str = "") -> list[Proposal]:
        with self._mu:
            out = [p for p in self._by_id.values() if not state or p.state == state]
        out.sort(key=lambda p: p.created_at, reverse=True)
        return out

    def resolve(self, proposal_id: str, state: str, approved_by: str) -> Proposal | None:
        """Move a proposal to a terminal state exactly once. Returns the
        updated proposal, or None if it is unknown or already decided."""
        with self._mu:
            p = self._by_id.get(proposal_id)
            if p is None or p.state != "proposed":
                return None
            p.state = state
            p.approved_by = approved_by
            p.decided_at = _now()
            return p


def _load_public_key() -> object | None:
    """Load the approval public key as a joserfc OKPKey. Returns None when no
    key is mounted, in which case approval verification always denies (fail
    closed). The key is the PUBLIC half only, so this process cannot sign."""
    path = config.APPROVAL_PUBKEY_FILE
    if not path or not os.path.exists(path):
        log.warning("approval public key not found at %s; all approvals will be denied", path)
        return None
    try:
        from joserfc.jwk import OKPKey
        with open(path, "rb") as f:
            return OKPKey.import_key(f.read())
    except Exception as exc:  # noqa: BLE001 (a bad key must fail closed)
        log.error("failed to load approval public key: %s", exc)
        return None


_PUBLIC_KEY = None
_KEY_LOADED = False


def _public_key() -> object | None:
    global _PUBLIC_KEY, _KEY_LOADED
    if not _KEY_LOADED:
        _PUBLIC_KEY = _load_public_key()
        _KEY_LOADED = True
    return _PUBLIC_KEY


def verify_approval(token: str, proposal: Proposal) -> str:
    """Verify an approval JWT against the pinned public key and bind it to this
    exact proposal. Returns the approver identity on success; raises
    ApprovalError on any failure. Fails closed when no key is loaded."""
    key = _public_key()
    if key is None:
        raise ApprovalError("no approval public key loaded; approvals denied")
    if not token or not isinstance(token, str):
        raise ApprovalError("no approval token presented")

    try:
        from joserfc import jwt
    except ImportError as exc:  # noqa: BLE001
        raise ApprovalError(f"jwt library unavailable: {exc}")

    try:
        decoded = jwt.decode(token, key, algorithms=ALGORITHMS)
    except Exception as exc:  # noqa: BLE001 (a bad signature is a denial)
        raise ApprovalError(f"token signature invalid: {exc}")

    claims = decoded.claims
    now = int(time.time())
    if claims.get("aud") != AUDIENCE:
        raise ApprovalError(f"token audience {claims.get('aud')!r} is not {AUDIENCE!r}")
    if claims.get("iss") != ISSUER:
        raise ApprovalError(f"token issuer {claims.get('iss')!r} is not {ISSUER!r}")
    exp = claims.get("exp")
    if not isinstance(exp, (int, float)) or exp < now:
        raise ApprovalError("token expired or missing exp")
    nbf = claims.get("nbf")
    if isinstance(nbf, (int, float)) and nbf > now + 60:
        raise ApprovalError("token not yet valid")
    # The token must have been minted for this exact proposal.
    if claims.get("sub") != proposal.proposal_id:
        raise ApprovalError("token subject does not match the proposal id")
    if claims.get("correlation_id") != proposal.correlation_id:
        raise ApprovalError("token correlation_id does not match the proposal")
    if claims.get("action") != proposal.action:
        raise ApprovalError("token action does not match the proposal")
    approver = str(claims.get("approved_by") or claims.get("sub_name") or "unknown")
    return approver
