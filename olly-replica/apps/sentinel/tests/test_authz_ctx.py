"""AuthZ-CTX across the Olly -> Orbit A2A hop (the receiving-agent half of the
ARC identity chain). Verifies the sentinel verifies a COIN token, narrows the
inbound permitted_actions by Orbit's local grant (never widens), and denies a
delegated action that does not survive narrowing."""

import base64
import hashlib
import hmac
import json
import time

import pytest

from olly_sentinel import authz, config

_READ = sorted(config.EEMS_SCOPES)


def _encode(claims: dict, secret: str, ttl: int = 300) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    payload = {**claims, "iat": now, "nbf": now, "exp": now + ttl}

    def b(x):
        return base64.urlsafe_b64encode(x).rstrip(b"=").decode()

    si = b(json.dumps(header).encode()) + "." + b(json.dumps(payload).encode())
    sig = hmac.new(secret.encode(), si.encode(), hashlib.sha256).digest()
    return si + "." + b(sig)


def _perm(actions: dict) -> list:
    return [{"action": a, "limit": lim} for a, lim in actions.items()]


def _sre_token() -> str:
    return _encode({"username": "e12345", "authz_ctx_id": "actx-test-sre",
                    "permitted_actions": _perm({**{s: 1 for s in _READ},
                                                "troubleshoot": 10, "restart_service": 3})},
                   config.AUTHZ_JWT_SECRET)


def _analyst_token() -> str:
    return _encode({"username": "e99999", "authz_ctx_id": "actx-test-analyst",
                    "permitted_actions": _perm({**{s: 1 for s in _READ}, "troubleshoot": 10})},
                   config.AUTHZ_JWT_SECRET)


def test_decode_roundtrips_a_coin_token():
    claims = authz.decode(_sre_token())
    assert claims["username"] == "e12345"
    assert claims["authz_ctx_id"] == "actx-test-sre"


def test_a2a_narrow_only_lowers_the_restart_limit():
    claims = authz.decode(_sre_token())
    narrowed = authz.to_map(authz.intersect(claims["permitted_actions"], config.ORBIT_LOCAL_GRANT))
    assert narrowed["restart_service"] == 1            # 3 -> 1, never widened
    assert authz.allows(authz.intersect(claims["permitted_actions"], config.ORBIT_LOCAL_GRANT),
                        "restart_service") is True


def test_analyst_cannot_delegate_a_restart():
    claims = authz.decode(_analyst_token())
    narrowed = authz.intersect(claims["permitted_actions"], config.ORBIT_LOCAL_GRANT)
    assert authz.allows(narrowed, "restart_service") is False   # the hop denies (403)
    assert authz.allows(narrowed, "troubleshoot") is True       # a read-only troubleshoot still passes


def test_forged_token_is_rejected():
    forged = _encode({"username": "e12345", "permitted_actions": []}, "wrong-secret")
    with pytest.raises(ValueError):
        authz.decode(forged)
