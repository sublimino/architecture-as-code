"""SLAAT-P1-2: Dex OIDC / Bearer token adversarial verification.

Attacks the token-verification boundary in ``api_compat.validate_jwt`` /
``api_compat.authenticated_principal`` directly, at the crypto/claims level,
rather than through a specific router. Complements the existing tenant-claim
spoofing coverage in ``test_tenant_isolation.py`` (which proves a forged
``tenant``/``tenant_id`` claim is never the authorisation decision) with the
lower-level attacks SLAAT-P1-2 was scoped for: algorithm confusion, signature
stripping, key-id substitution, and malformed-JWS structural attacks.

Every test asserts the production verifier fails closed -- ``JWTValidationError``
at the unit level, HTTP 401/403 at the dependency level -- never a 500, and
never a bypass. A test in this file that goes green is evidence a specific
attack does NOT work against this codebase today; that is the intended,
useful outcome for a Phase 1 probing card (see KPI: "successful adversarial
probe bypasses on final re-test = 0").
"""
from __future__ import annotations

import base64
import json
import time
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from fastapi import FastAPI
from fastapi.testclient import TestClient

import api_compat
from api_compat import APIError, JWTValidationError, settings
from conftest import (
    EAP_AUDIENCE,
    EAP_AZP,
    EAP_ISSUER,
    EAP_KEY_ID,
    EAP_ALICE,
    EAP_TENANT_A,
    _EAP_SIGNING_KEY,
    configure_eap_jwt,
    eap_token_for,
)

EAP_AUTHENTICATED = True  # opt in to conftest's autouse JWT verifier wiring


# ---------------------------------------------------------------------------
# Low-level JWS crafting helpers -- deliberately independent of PyJWT's own
# encode path so a test can produce byte-for-byte malformed structures
# (duplicate keys, non-object payloads, raw JSON constants) that
# ``jwt.encode(dict, ...)`` cannot represent because Python dicts cannot hold
# a duplicate key in the first place.
# ---------------------------------------------------------------------------


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(segment: str) -> bytes:
    return base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4))


def _rs256_sign(signing_input: bytes, private_key: rsa.RSAPrivateKey) -> bytes:
    return private_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())


def _hs256_sign(signing_input: bytes, secret: bytes) -> bytes:
    """Raw HMAC-SHA256, bypassing PyJWT's own asymmetric-key guard.

    PyJWT's ``HMACAlgorithm.prepare_key`` refuses a PEM-formatted key outright
    (``InvalidKeyError``), which blocks the classic RS256->HS256 confusion
    attack at the *client library* layer before a token can even be minted.
    An attacker is not required to use PyJWT to forge a token, so the
    adversarial test has to construct the HMAC byte-for-byte to find out
    whether *this application's* verifier -- not the library -- is what
    actually stops the attack.
    """
    import hmac as _hmac_mod

    return _hmac_mod.new(secret, signing_input, "sha256").digest()


def _craft_hs256_token(header: dict[str, Any], payload_bytes: bytes, secret: bytes) -> str:
    header_b64 = _b64url(json.dumps(header, separators=(",", ":")).encode())
    payload_b64 = _b64url(payload_bytes)
    signing_input = f"{header_b64}.{payload_b64}".encode()
    signature = _hs256_sign(signing_input, secret)
    return f"{signing_input.decode()}.{_b64url(signature)}"


def _craft_rs256_token(
    header: dict[str, Any],
    payload_bytes: bytes,
    *,
    key: rsa.RSAPrivateKey = _EAP_SIGNING_KEY,
) -> str:
    """A syntactically-valid RS256 JWS over an attacker-chosen exact payload."""
    header_b64 = _b64url(json.dumps(header, separators=(",", ":")).encode())
    payload_b64 = _b64url(payload_bytes)
    signing_input = f"{header_b64}.{payload_b64}".encode()
    signature = _rs256_sign(signing_input, key)
    return f"{signing_input.decode()}.{_b64url(signature)}"


def _valid_claims(**overrides: Any) -> dict[str, Any]:
    now = int(time.time())
    claims = {
        "iss": EAP_ISSUER,
        "aud": EAP_AUDIENCE,
        "sub": EAP_ALICE,
        "iat": now,
        "nbf": now,
        "exp": now + 300,
        "azp": EAP_AZP,
    }
    claims.update(overrides)
    return claims


@pytest.fixture(autouse=True)
def _jwt_env(monkeypatch: pytest.MonkeyPatch) -> None:
    configure_eap_jwt(monkeypatch)


# ---------------------------------------------------------------------------
# Control case
# ---------------------------------------------------------------------------


def test_valid_rs256_token_is_accepted():
    """Sanity control: a correctly-signed, correctly-claimed token passes."""
    claims = api_compat.validate_jwt(eap_token_for(EAP_ALICE))
    assert claims["sub"] == EAP_ALICE

    principal = api_compat.authenticated_principal(f"Bearer {eap_token_for(EAP_ALICE)}")
    assert principal.tenant == EAP_TENANT_A


# ---------------------------------------------------------------------------
# Algorithm confusion
# ---------------------------------------------------------------------------


def test_alg_none_is_rejected():
    """The classic 'alg: none' JWT attack: no signature, trust the claims as-is."""
    header = {"alg": "none", "typ": "JWT", "kid": EAP_KEY_ID}
    payload = json.dumps(_valid_claims()).encode()
    token = f"{_b64url(json.dumps(header).encode())}.{_b64url(payload)}."
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(token)


def test_hs256_confusion_using_rsa_public_key_as_hmac_secret():
    """Classic RS256->HS256 key-confusion: sign with the RSA public key as an HMAC secret.

    This only works against a verifier that passes whatever "key" it looked up
    straight into ``jwt.decode`` without re-asserting the algorithm. This
    verifier checks ``header["alg"] != "RS256"`` before ever doing a JWKS
    lookup, and separately pins ``algorithms=["RS256"]`` in the eventual
    ``jwt.decode`` call -- two independent reasons this must fail closed.
    """
    public_pem = _EAP_SIGNING_KEY.public_key().public_bytes(
        Encoding.PEM, PublicFormat.SubjectPublicKeyInfo
    )
    header = {"alg": "HS256", "typ": "JWT", "kid": EAP_KEY_ID}
    payload = json.dumps(_valid_claims()).encode()
    forged = _craft_hs256_token(header, payload, secret=public_pem)
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(forged)


def test_alg_header_case_variant_is_rejected():
    """'rs256' / 'Rs256' must not be treated as equal to the pinned 'RS256'."""
    for alg_variant in ("rs256", "Rs256", "RS256 "):
        header = {"alg": alg_variant, "typ": "JWT", "kid": EAP_KEY_ID}
        payload = json.dumps(_valid_claims()).encode()
        token = _craft_rs256_token(header, payload)
        with pytest.raises(JWTValidationError):
            api_compat.validate_jwt(token)


# ---------------------------------------------------------------------------
# Key identifier attacks
# ---------------------------------------------------------------------------


def test_unknown_kid_is_rejected():
    token = eap_token_for(EAP_ALICE)
    header_b64, payload_b64, sig_b64 = token.split(".")
    header = json.loads(_b64url_decode(header_b64))
    header["kid"] = "attacker-supplied-kid"
    tampered = f"{_b64url(json.dumps(header).encode())}.{payload_b64}.{sig_b64}"
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(tampered)


def test_missing_kid_is_rejected():
    header = {"alg": "RS256", "typ": "JWT"}
    payload = json.dumps(_valid_claims()).encode()
    token = _craft_rs256_token(header, payload)
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(token)


def test_cross_key_substitution_with_claimed_production_kid_is_rejected():
    """A second, attacker-held RSA keypair signs a token but claims the real ``kid``.

    The stub JWKS client (and, in production, the real JWKS endpoint) only
    knows one public key for ``EAP_KEY_ID``; a signature produced by a
    different private key must fail verification against it.
    """
    attacker_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    header = {"alg": "RS256", "typ": "JWT", "kid": EAP_KEY_ID}
    payload = json.dumps(_valid_claims()).encode()
    forged = _craft_rs256_token(header, payload, key=attacker_key)
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(forged)


# ---------------------------------------------------------------------------
# Signature / structural tampering
# ---------------------------------------------------------------------------


def test_signature_stripped_is_rejected():
    token = eap_token_for(EAP_ALICE)
    header_b64, payload_b64, _sig = token.split(".")
    stripped = f"{header_b64}.{payload_b64}."
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(stripped)


def test_two_segment_token_is_rejected():
    token = eap_token_for(EAP_ALICE)
    header_b64, payload_b64, _sig = token.split(".")
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(f"{header_b64}.{payload_b64}")


def test_payload_tampered_after_signing_is_rejected():
    """Decode, mutate a claim, re-encode, keep the ORIGINAL signature. Must fail."""
    token = eap_token_for(EAP_ALICE)
    header_b64, payload_b64, sig_b64 = token.split(".")
    claims = json.loads(_b64url_decode(payload_b64))
    claims["sub"] = "mallory"
    tampered_payload_b64 = _b64url(json.dumps(claims).encode())
    tampered = f"{header_b64}.{tampered_payload_b64}.{sig_b64}"
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(tampered)


def test_duplicate_json_keys_in_payload_is_rejected():
    """A JWT whose payload JSON repeats a key (e.g. two 'sub' values)."""
    header = {"alg": "RS256", "typ": "JWT", "kid": EAP_KEY_ID}
    now = int(time.time())
    payload_text = (
        '{"iss":"%s","aud":"%s","sub":"alice","sub":"mallory",'
        '"iat":%d,"nbf":%d,"exp":%d,"azp":"%s"}'
        % (EAP_ISSUER, EAP_AUDIENCE, now, now, now + 300, EAP_AZP)
    )
    token = _craft_rs256_token(header, payload_text.encode())
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(token)


def test_non_object_payload_is_rejected():
    """Payload segment decodes to a JSON array, not an object."""
    header = {"alg": "RS256", "typ": "JWT", "kid": EAP_KEY_ID}
    token = _craft_rs256_token(header, b"[1,2,3]")
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(token)


def test_json_constant_nan_in_payload_is_rejected():
    """A non-standard JSON constant (NaN) smuggled into a claim value."""
    header = {"alg": "RS256", "typ": "JWT", "kid": EAP_KEY_ID}
    payload_text = (
        '{"iss":"%s","aud":"%s","sub":"alice","iat":1,"nbf":1,"exp":NaN,"azp":"%s"}'
        % (EAP_ISSUER, EAP_AUDIENCE, EAP_AZP)
    )
    token = _craft_rs256_token(header, payload_text.encode())
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(token)


def test_malformed_base64_segment_is_rejected():
    token = eap_token_for(EAP_ALICE)
    header_b64, _payload_b64, sig_b64 = token.split(".")
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(f"{header_b64}.not!!valid!!base64.{sig_b64}")


# ---------------------------------------------------------------------------
# Claims-level attacks
# ---------------------------------------------------------------------------


def test_expired_token_is_rejected():
    expired = eap_token_for(EAP_ALICE, lifetime=-10)
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(expired)


def test_not_yet_valid_token_is_rejected():
    now = int(time.time())
    claims = _valid_claims(nbf=now + 600, exp=now + 900)
    token = jwt.encode(claims, _EAP_SIGNING_KEY, algorithm="RS256", headers={"kid": EAP_KEY_ID, "typ": "JWT"})
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(token)


def test_wrong_audience_is_rejected():
    token = eap_token_for(EAP_ALICE, extra_claims={"aud": "some-other-service"})
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(token)


def test_wrong_issuer_is_rejected():
    token = eap_token_for(EAP_ALICE, extra_claims={"iss": "https://attacker.example/dex"})
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(token)


def test_wrong_authorized_party_is_rejected():
    token = eap_token_for(EAP_ALICE, extra_claims={"azp": "some-other-client"})
    with pytest.raises(JWTValidationError):
        api_compat.validate_jwt(token)


def test_empty_subject_is_rejected():
    for bad_sub in ("", "   "):
        token = eap_token_for(EAP_ALICE, extra_claims={"sub": bad_sub})
        with pytest.raises(JWTValidationError):
            api_compat.validate_jwt(token)


def test_forged_tenant_claim_is_never_the_authorisation_decision():
    """A valid, correctly-signed token for alice, carrying a forged ``tenant``
    claim naming tenant-b. The server must still resolve alice's tenant via
    ``settings.api_subject_tenants[sub]`` (tenant-a), never via the claim.
    """
    forged = eap_token_for(EAP_ALICE, extra_claims={"tenant": "tenant-b", "tenant_id": "tenant-b"})
    principal = api_compat.authenticated_principal(f"Bearer {forged}")
    assert principal.tenant == EAP_TENANT_A, "a client-asserted tenant claim must never win"


def test_unmapped_subject_is_tenant_forbidden():
    token = eap_token_for("subject-with-no-tenant-mapping")
    with pytest.raises(APIError) as exc_info:
        api_compat.authenticated_principal(f"Bearer {token}")
    assert exc_info.value.status_code == 403


def test_host_credential_scoped_token_cannot_reach_operator_apis():
    """A token scoped to audit-upload-only (external host credential) must be
    rejected for the operator control-plane dependency even with a valid signature.
    """
    for extra in ({"scope": "audit-upload-only"}, {"identity_type": "external-host"}):
        token = eap_token_for(EAP_ALICE, extra_claims=extra)
        with pytest.raises(APIError) as exc_info:
            api_compat.authenticated_principal(f"Bearer {token}")
        assert exc_info.value.status_code == 403


# ---------------------------------------------------------------------------
# Authorization header grammar attacks
# ---------------------------------------------------------------------------


def test_missing_authorization_header_is_401():
    with pytest.raises(APIError) as exc_info:
        api_compat.authenticated_principal(None)
    assert exc_info.value.status_code == 401


@pytest.mark.parametrize(
    "header_value",
    [
        "",
        "Bearer",
        "Bearer ",
        "Bearer    ",
        "NotBearer sometoken",
        "Basic dXNlcjpwYXNz",
        "Bearer token with spaces",
        "Bearer\ttoken-with-tab",
    ],
)
def test_malformed_authorization_header_grammar_is_rejected(header_value: str):
    with pytest.raises(APIError) as exc_info:
        api_compat.authenticated_principal(header_value)
    assert exc_info.value.status_code == 401


def test_lowercase_bearer_scheme_is_still_accepted():
    """Documents intended leniency: the scheme match is case-insensitive.

    Not a vulnerability -- the token itself is still fully verified; only the
    literal word 'bearer' is accepted case-insensitively, which is standard
    HTTP token grammar (RFC 7235 schemes are case-insensitive).
    """
    token = eap_token_for(EAP_ALICE)
    principal = api_compat.authenticated_principal(f"bearer {token}")
    assert principal.tenant == EAP_TENANT_A


# ---------------------------------------------------------------------------
# End-to-end: the dependency wired into a real route, not just the unit function
# ---------------------------------------------------------------------------


def test_e2e_forged_token_rejected_by_real_route(client: "TestClient"):
    resp = client.get("/api/v1/eap/tenants", headers={"Authorization": "Bearer not-a-jwt"})
    assert resp.status_code == 401
    body = resp.json()
    assert "Traceback" not in json.dumps(body)


def test_e2e_hs256_confusion_rejected_by_real_route(client: "TestClient"):
    public_pem = _EAP_SIGNING_KEY.public_key().public_bytes(
        Encoding.PEM, PublicFormat.SubjectPublicKeyInfo
    )
    header = {"alg": "HS256", "typ": "JWT", "kid": EAP_KEY_ID}
    payload = json.dumps(_valid_claims()).encode()
    forged = _craft_hs256_token(header, payload, secret=public_pem)
    resp = client.get("/api/v1/eap/tenants", headers={"Authorization": f"Bearer {forged}"})
    assert resp.status_code == 401


def test_e2e_error_response_never_leaks_internals(client: "TestClient"):
    """A battery of malformed tokens against a real route: every response must
    be the generic envelope, never a stack trace, SQL text, or Python
    exception repr.
    """
    forbidden_substrings = (
        "Traceback",
        "asyncpg",
        "psycopg",
        "File \"",
        "Exception",
        "  at ",
        "SELECT ",
        "INSERT ",
    )
    attacks = [
        "Bearer " + "A" * 5000,
        "Bearer " + eap_token_for(EAP_ALICE)[:-5],
        "Bearer null",
        "Bearer {}",
    ]
    for header_value in attacks:
        resp = client.get("/api/v1/eap/tenants", headers={"Authorization": header_value})
        assert resp.status_code in (401, 403, 404, 422), (header_value, resp.status_code, resp.text)
        text = resp.text
        for needle in forbidden_substrings:
            assert needle not in text, f"leaked internal detail {needle!r} for {header_value!r}: {text}"


@pytest.fixture
def client() -> "TestClient":
    app = FastAPI()
    api_compat.install_compatibility_api(app)
    import tenant_isolation

    tenant_isolation.install_tenant_isolation_api(app)
    with TestClient(app, raise_server_exceptions=False) as tc:
        yield tc
