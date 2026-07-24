"""Orbit approval gate: the strategic decision, made un-forgeable.

These are the security assertions for the action path. The load-bearing
property is that the sentinel holds only the PUBLIC approval key, so no token
it could produce itself will verify, so an approval must come from the broker,
which holds the private half. The tests mint tokens with a throwaway keypair
and point the verifier at its public half, exercising the real joserfc EdDSA
path (no mock), then prove that:

  * an unsigned / missing token is denied,
  * a token signed by the WRONG key (the forge attack) is denied,
  * a token bound to a DIFFERENT proposal is denied (no replay),
  * an expired token is denied,
  * a correctly-signed, correctly-bound token approves,
  * remediate_restart_service is proposed only for a restart-shaped
    infrastructure fault, and the executor never mutates in Phase 1.
"""

import time

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import (
    Encoding, NoEncryption, PrivateFormat, PublicFormat,
)

from olly_sentinel import approval, config, orbit


def _keypair(tmp_path, name="orbit-approval"):
    priv = Ed25519PrivateKey.generate()
    pub = priv.public_key()
    priv_pem = priv.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    pub_pem = pub.public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo)
    pub_path = tmp_path / f"{name}-pub.pem"
    pub_path.write_bytes(pub_pem)
    return priv_pem, str(pub_path)


def _mint(priv_pem, claims):
    from joserfc import jwt
    from joserfc.jwk import OKPKey
    key = OKPKey.import_key(priv_pem)
    return jwt.encode({"alg": "EdDSA"}, claims, key, algorithms=["EdDSA"])


def _reset_key_cache(monkeypatch, pub_path):
    # approval caches the loaded key at module scope; reset it per test.
    monkeypatch.setattr(approval, "_PUBLIC_KEY", None, raising=False)
    monkeypatch.setattr(approval, "_KEY_LOADED", False, raising=False)
    monkeypatch.setattr(config, "APPROVAL_PUBKEY_FILE", pub_path)


def _proposal(action="remediate_restart_service"):
    return approval.Proposal(
        proposal_id="prop-test-001",
        correlation_id="corr-test-001",
        app_id="payments-api",
        action=action,
        justification="test",
    )


def _claims(p, priv_pem=None, **overrides):
    now = int(time.time())
    base = {
        "iss": approval.ISSUER,
        "aud": approval.AUDIENCE,
        "sub": p.proposal_id,
        "correlation_id": p.correlation_id,
        "action": p.action,
        "approved_by": "torin",
        "iat": now,
        "exp": now + 300,
    }
    base.update(overrides)
    return base


def test_missing_token_denied(tmp_path, monkeypatch):
    priv_pem, pub_path = _keypair(tmp_path)
    _reset_key_cache(monkeypatch, pub_path)
    with pytest.raises(approval.ApprovalError):
        approval.verify_approval("", _proposal())


def test_forged_token_denied(tmp_path, monkeypatch):
    """A token signed by a key that is NOT the mounted approval key must fail.
    The sentinel holds only the public half, so it cannot produce a valid one."""
    _, pub_path = _keypair(tmp_path)                 # the trusted public key
    forge_priv, _ = _keypair(tmp_path, "attacker")   # a different private key
    _reset_key_cache(monkeypatch, pub_path)
    p = _proposal()
    forged = _mint(forge_priv, _claims(p))
    with pytest.raises(approval.ApprovalError):
        approval.verify_approval(forged, p)


def test_replayed_token_denied(tmp_path, monkeypatch):
    """A validly-signed token minted for a different proposal must not approve
    this one; the claims bind it to a single proposal_id/correlation_id."""
    priv_pem, pub_path = _keypair(tmp_path)
    _reset_key_cache(monkeypatch, pub_path)
    other = approval.Proposal(proposal_id="prop-OTHER", correlation_id="corr-OTHER",
                              app_id="payments-api", action="remediate_restart_service",
                              justification="x")
    token_for_other = _mint(priv_pem, _claims(other))
    with pytest.raises(approval.ApprovalError):
        approval.verify_approval(token_for_other, _proposal())


def test_expired_token_denied(tmp_path, monkeypatch):
    priv_pem, pub_path = _keypair(tmp_path)
    _reset_key_cache(monkeypatch, pub_path)
    p = _proposal()
    now = int(time.time())
    expired = _mint(priv_pem, _claims(p, iat=now - 600, exp=now - 300))
    with pytest.raises(approval.ApprovalError):
        approval.verify_approval(expired, p)


def test_valid_token_approves(tmp_path, monkeypatch):
    priv_pem, pub_path = _keypair(tmp_path)
    _reset_key_cache(monkeypatch, pub_path)
    p = _proposal()
    token = _mint(priv_pem, _claims(p))
    approver = approval.verify_approval(token, p)
    assert approver == "torin"


def test_remediate_proposed_only_for_restart_shape():
    infra_restart = {
        "correlation_id": "c1", "idempotency_key": "k1", "app_id": "payments-api",
        "rca": {"fault_domain": "infrastructure",
                "probable_cause": "settlement worker OOMKilled mid EOD batch"},
        "evidence": [],
    }
    infra_other = {
        "correlation_id": "c2", "idempotency_key": "k2", "app_id": "payments-api",
        "rca": {"fault_domain": "infrastructure", "probable_cause": "disk pressure on node"},
        "evidence": [],
    }
    dep = {
        "correlation_id": "c3", "idempotency_key": "k3", "app_id": "inventory-service",
        "rca": {"fault_domain": "dependency", "probable_cause": "pool exhausted"},
        "evidence": [],
    }
    assert orbit.propose(infra_restart)["action"] == "remediate_restart_service"
    assert orbit.propose(infra_other)["action"] == "no_action"
    assert orbit.propose(dep)["action"] == "troubleshoot"


def test_executor_never_mutates():
    """The Phase-1 executor records what it WOULD do and returns an executed
    proposal, but performs no mutation."""
    p = {
        "schema_version": "v1", "proposal_id": "prop-x", "correlation_id": "c",
        "app_id": "payments-api", "action": "remediate_restart_service",
        "justification": "j", "approval": {"state": "approved"},
    }
    out = orbit.execute(p, "torin")
    assert out["approval"]["state"] == "executed"
    assert out["approval"]["approved_by"] == "torin"
    assert "WOULD restart" in out["execution_note"]
