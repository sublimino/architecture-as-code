"""Adversarial tests: lifecycle state machine violations.

Probes the agent lifecycle transition graph for:
  - Invalid target states (arbitrary strings, SQL injection, empty)
  - Forbidden transitions (decommissioned -> active, revoked -> active)
  - Double transitions to the same state
  - Self-transitions (active -> active)
  - Terminal state enforcement (revoked and decommissioned are absorbing)
"""
from __future__ import annotations

import socket
import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import (
    VALID_LIFECYCLE_STATES,
    VALID_TRANSITIONS,
    reset_tenant_state,
    settings,
)
import api_compat as _api_compat_module
from db.connection import set_pool_for_testing
from main import app

# ---------------------------------------------------------------------------
# Test JWT infrastructure (same pattern as test_adversarial_input.py)
# ---------------------------------------------------------------------------

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _token_for(subject: str = "alice", **extra) -> str:
    now = int(time.time())
    claims = {
        "iss": "https://issuer.test/dex",
        "aud": "signalloom-api",
        "iat": now, "nbf": now, "exp": now + 300,
        "azp": "signalloom-dashboard",
        "sub": subject,
        "email": f"{subject}@corp.test",
    }
    claims.update(extra)
    return jwt.encode(
        claims, TEST_SIGNING_KEY, algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


class _ReadyPool:
    async def close(self):
        pass


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {"alice": "tenant-a"})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    def reject_external(*_a, **_kw):
        raise AssertionError("no external network in tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external)
    set_pool_for_testing(_ReadyPool())
    reset_tenant_state("tenant-a")

    with TestClient(app, raise_server_exceptions=False) as tc:
        yield tc


AUTH = lambda: _bearer(_token_for("alice"))

TENANT_AGENT = "tenant-a:agent-1"


def _transition(client, agent_id: str, to_state: str, reason: str = "test"):
    return client.post(
        f"/api/agents/{agent_id}/transition",
        headers=AUTH(),
        json={"to_state": to_state, "reason": reason},
    )


# =========================================================================
# 1. Invalid target states — must be rejected with 400
# =========================================================================

class TestInvalidTargetStates:
    """TransitionRequest.to_state must be a member of VALID_LIFECYCLE_STATES.
    Before the fix, any string was accepted in fixture mode."""

    @pytest.mark.parametrize("bad_state", [
        "",                              # empty
        " ",                             # whitespace
        "ACTIVE",                        # wrong case
        "nonexistent_state",             # not in vocabulary
        "hacked",                        # arbitrary
        "'; DROP TABLE agents;--",       # SQL injection
        "<script>alert(1)</script>",     # XSS
        "a" * 10_000,                    # overlong
        "registered\x00active",          # null byte
        "Active",                        # title case
        "SUSPENDED",                     # upper case
    ])
    def test_invalid_to_state_rejected(self, client, bad_state):
        resp = _transition(client, TENANT_AGENT, bad_state)
        assert resp.status_code == 400, (
            f"Expected 400 for invalid state {bad_state!r}, got {resp.status_code}: {resp.text}"
        )
        body = resp.json()
        assert body["error"]["code"] == "invalid_state"


# =========================================================================
# 2. Forbidden transitions — must be rejected with 409
# =========================================================================

class TestForbiddenTransitions:
    """The transition graph enforces directionality. Terminal states
    (revoked, decommissioned) are absorbing — no outbound edges."""

    def test_decommissioned_to_active_forbidden(self, client):
        """Once decommissioned, an agent cannot come back to life."""
        # First, move to decommissioned (valid: registered -> decommissioned)
        resp = _transition(client, TENANT_AGENT, "decommissioned")
        assert resp.status_code == 200, f"Setup failed: {resp.text}"

        # Now try to bring it back — must be rejected
        resp = _transition(client, TENANT_AGENT, "active")
        assert resp.status_code == 409, (
            f"Expected 409 for decommissioned->active, got {resp.status_code}: {resp.text}"
        )
        body = resp.json()
        assert body["error"]["code"] == "invalid_transition"

    def test_revoked_to_active_forbidden(self, client):
        """Once revoked, an agent cannot be reinstated."""
        resp = _transition(client, TENANT_AGENT, "revoked")
        assert resp.status_code == 200

        resp = _transition(client, TENANT_AGENT, "active")
        assert resp.status_code == 409
        assert resp.json()["error"]["code"] == "invalid_transition"

    def test_revoked_to_suspended_forbidden(self, client):
        """Revoked is terminal — no transitions at all."""
        resp = _transition(client, TENANT_AGENT, "revoked")
        assert resp.status_code == 200

        resp = _transition(client, TENANT_AGENT, "suspended")
        assert resp.status_code == 409

    def test_decommissioned_to_enrolled_forbidden(self, client):
        """Decommissioned is terminal — cannot re-enroll."""
        resp = _transition(client, TENANT_AGENT, "decommissioned")
        assert resp.status_code == 200

        resp = _transition(client, TENANT_AGENT, "enrolled")
        assert resp.status_code == 409

    def test_active_to_enrolled_forbidden(self, client):
        """Cannot go backwards from active to enrolled."""
        # agent-1 starts as "active" in seed data
        resp = _transition(client, TENANT_AGENT, "enrolled")
        assert resp.status_code == 409, (
            f"Expected 409 for active->enrolled, got {resp.status_code}: {resp.text}"
        )

    def test_active_to_registered_forbidden(self, client):
        """Cannot go backwards from active to registered."""
        resp = _transition(client, TENANT_AGENT, "registered")
        assert resp.status_code == 409


# =========================================================================
# 3. Valid transitions — must succeed
# =========================================================================

class TestValidTransitions:
    """Confirm the happy-path transitions still work after adding validation."""

    def test_active_to_suspended(self, client):
        resp = _transition(client, TENANT_AGENT, "suspended")
        assert resp.status_code == 200
        body = resp.json()
        assert body["from_state"] == "active"
        assert body["to_state"] == "suspended"

    def test_suspended_to_active(self, client):
        # First suspend
        resp = _transition(client, TENANT_AGENT, "suspended")
        assert resp.status_code == 200
        # Then reinstate
        resp = _transition(client, TENANT_AGENT, "active")
        assert resp.status_code == 200
        body = resp.json()
        assert body["from_state"] == "suspended"
        assert body["to_state"] == "active"

    def test_active_to_decommissioned(self, client):
        resp = _transition(client, TENANT_AGENT, "decommissioned")
        assert resp.status_code == 200

    def test_active_to_revoked(self, client):
        resp = _transition(client, TENANT_AGENT, "revoked")
        assert resp.status_code == 200

    def test_registered_to_active(self, client):
        """agent-2 starts as 'registered' in seed data."""
        resp = _transition(client, "tenant-a:agent-2", "active")
        assert resp.status_code == 200
        body = resp.json()
        assert body["from_state"] == "registered"
        assert body["to_state"] == "active"

    def test_registered_to_enrolled(self, client):
        resp = _transition(client, "tenant-a:agent-2", "enrolled")
        assert resp.status_code == 200


# =========================================================================
# 4. State machine consistency — graph properties
# =========================================================================

class TestStateMachineConsistency:
    """Verify structural properties of the transition graph itself."""

    def test_every_valid_state_has_a_transitions_entry(self):
        """Every state in VALID_LIFECYCLE_STATES appears as a key in
        VALID_TRANSITIONS, so the lookup never falls through to None."""
        for state in VALID_LIFECYCLE_STATES:
            assert state in VALID_TRANSITIONS, (
                f"State {state!r} is in VALID_LIFECYCLE_STATES but not in "
                f"VALID_TRANSITIONS — the transition graph has no entry for it"
            )

    def test_all_transition_targets_are_valid_states(self):
        """Every target in the transition graph must itself be a valid state.
        A typo in the graph silently creates an unreachable state."""
        for from_state, targets in VALID_TRANSITIONS.items():
            for target in targets:
                assert target in VALID_LIFECYCLE_STATES, (
                    f"VALID_TRANSITIONS[{from_state!r}] includes {target!r} "
                    f"which is not in VALID_LIFECYCLE_STATES"
                )

    def test_terminal_states_have_no_outbound_edges(self):
        """Revoked and decommissioned must be absorbing states."""
        for terminal in ("revoked", "decommissioned"):
            targets = VALID_TRANSITIONS.get(terminal, frozenset())
            assert len(targets) == 0, (
                f"Terminal state {terminal!r} has outbound edges: {targets}"
            )

    def test_no_self_transitions_in_graph(self):
        """No state should be able to transition to itself."""
        for from_state, targets in VALID_TRANSITIONS.items():
            assert from_state not in targets, (
                f"VALID_TRANSITIONS[{from_state!r}] includes itself — "
                f"self-transitions should not be in the graph"
            )


# =========================================================================
# 5. Double transition (idempotency probe)
# =========================================================================

class TestDoubleTransition:
    """Transitioning to the same state twice should either succeed idempotently
    or be rejected, but must never corrupt state."""

    def test_active_to_suspended_twice(self, client):
        """First transition succeeds. Second is a self-transition
        (suspended -> suspended) and should be rejected as invalid."""
        resp = _transition(client, TENANT_AGENT, "suspended")
        assert resp.status_code == 200

        resp = _transition(client, TENANT_AGENT, "suspended")
        # suspended -> suspended is not in the graph — no self-transitions
        assert resp.status_code == 409, (
            f"Double transition should be rejected, got {resp.status_code}: {resp.text}"
        )


# =========================================================================
# 6. Stun handler must respect the transition graph
# =========================================================================

@pytest.fixture
def stun_client(monkeypatch):
    """Client with SUPERCRED_STUN_BASE_URL cleared so the simulated path runs
    (no actual network call) and acted=True, exercising the state-change code."""
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {"alice": "tenant-a"})
    monkeypatch.setattr(_api_compat_module, "_jwk_client", lambda _url: _TestJWKClient())
    monkeypatch.setattr(_api_compat_module, "SUPERCRED_STUN_BASE_URL", "")

    set_pool_for_testing(_ReadyPool())
    reset_tenant_state("tenant-a")

    with TestClient(app, raise_server_exceptions=False) as tc:
        yield tc


def _stun(client, agent_id: str):
    return client.post(
        f"/api/agents/{agent_id}/stun",
        headers=AUTH(),
    )


class TestStunRespectsTransitionGraph:
    """The stun handler sets lifecycle_state to 'suspended'. Before the fix,
    it did not call _validate_transition, so a revoked or decommissioned agent
    could be stunned back to 'suspended' -- violating the terminal-state
    invariant and silently resurrecting a dead agent."""

    def test_stun_revoked_agent_rejected(self, stun_client):
        """A revoked agent cannot be stunned back to suspended."""
        # Move to revoked (terminal state)
        resp = _transition(stun_client, TENANT_AGENT, "revoked")
        assert resp.status_code == 200, f"Setup failed: {resp.text}"

        # Stun must not resurrect it
        resp = _stun(stun_client, TENANT_AGENT)
        assert resp.status_code == 409, (
            f"Stun should reject revoked agent, got {resp.status_code}: {resp.text}"
        )

    def test_stun_decommissioned_agent_rejected(self, stun_client):
        """A decommissioned agent cannot be stunned back to suspended."""
        resp = _transition(stun_client, TENANT_AGENT, "decommissioned")
        assert resp.status_code == 200, f"Setup failed: {resp.text}"

        resp = _stun(stun_client, TENANT_AGENT)
        assert resp.status_code == 409, (
            f"Stun should reject decommissioned agent, got {resp.status_code}: {resp.text}"
        )

    def test_stun_active_agent_succeeds(self, stun_client):
        """An active agent can be stunned (active -> suspended is valid)."""
        resp = _stun(stun_client, TENANT_AGENT)
        assert resp.status_code == 200, (
            f"Stun of active agent should succeed, got {resp.status_code}: {resp.text}"
        )
        body = resp.json()
        assert body["from_state"] == "active"
        assert body["to_state"] == "suspended"

    def test_stun_already_suspended_rejected(self, stun_client):
        """Stunning an already-suspended agent is a self-transition
        (suspended -> suspended) and must be rejected."""
        # First stun: active -> suspended
        resp = _stun(stun_client, TENANT_AGENT)
        assert resp.status_code == 200

        # Second stun: suspended -> suspended (self-transition, not in graph)
        resp = _stun(stun_client, TENANT_AGENT)
        assert resp.status_code == 409, (
            f"Double stun should be rejected, got {resp.status_code}: {resp.text}"
        )
