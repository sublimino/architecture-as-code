"""A tiny stdlib HS256 JWT so the identity chain runs with plain python3 and no
third-party dependency. It carries the same claims a COIN-issued token does
(username, permitted_actions, authz_ctx_id); every verifier shares the secret."""

import base64
import hashlib
import hmac
import json
import time


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _unb64(seg: str) -> bytes:
    return base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4))


def encode(claims: dict, secret: str, ttl: int = 300) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    payload = {**claims, "iat": now, "nbf": now, "exp": now + ttl}
    signing_input = _b64(json.dumps(header).encode()) + "." + _b64(json.dumps(payload).encode())
    sig = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
    return signing_input + "." + _b64(sig)


def decode(token: str, secret: str) -> dict:
    """Verify signature + exp/nbf and return the claims. Raises ValueError on any
    failure, so a caller can turn a bad token into a clean DENY."""
    parts = (token or "").split(".")
    if len(parts) != 3:
        raise ValueError("malformed token")
    signing_input = parts[0] + "." + parts[1]
    expected = _b64(hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest())
    if not hmac.compare_digest(expected, parts[2]):
        raise ValueError("bad signature")
    claims = json.loads(_unb64(parts[1]))
    now = int(time.time())
    if claims.get("exp", 0) < now:
        raise ValueError("token expired")
    if claims.get("nbf", 0) > now + 5:
        raise ValueError("token not yet valid")
    return claims
