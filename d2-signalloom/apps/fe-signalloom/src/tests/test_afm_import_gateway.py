"""Tests for the authenticated AFM import gateway route: POST /api/v1/afm/clusters/import.

Ensures that fe-signalloom accepts only the named static key afm-importer
holding scope afm:import and bound to a specific cluster id, and forwards
the raw payload to upstream afm-platform without leaking credentials.
"""
from __future__ import annotations

import base64
import datetime
import hashlib
import hmac
import json
import secrets
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from db.connection import set_pool_for_testing
from main import app
from conftest import EAP_ALICE, EAP_OPERATOR, eap_bearer

DEFAULT_CLUSTER = "kind-osramp"
DEFAULT_KEY_NAME = "afm-importer"


def _make_key() -> str:
    """Generate a high-entropy random key >= 32 bytes at test time."""
    return secrets.token_urlsafe(32)


def _rfc3339(dt: datetime.datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


@pytest.fixture(autouse=True)
def _clean_pool():
    set_pool_for_testing(None)


@pytest.fixture()
def key_env(tmp_path, monkeypatch):
    """Sets up a valid key environment in a temporary directory."""
    token = _make_key()
    now = datetime.datetime.now(datetime.timezone.utc)
    expires = now + datetime.timedelta(days=90)

    key_file = tmp_path / DEFAULT_KEY_NAME
    key_file.write_text(token, encoding="utf-8")

    expires_file = tmp_path / f"{DEFAULT_KEY_NAME}.expires"
    expires_file.write_text(_rfc3339(expires), encoding="utf-8")

    key_spec = [
        {
            "name": DEFAULT_KEY_NAME,
            "scopes": ["afm:import"],
            "cluster": DEFAULT_CLUSTER,
        }
    ]
    monkeypatch.setenv("AFM_IMPORTER_KEY_DIR", str(tmp_path))
    monkeypatch.setenv("AFM_IMPORT_KEYS", json.dumps(key_spec))
    monkeypatch.setenv("AFM_BASE_URL", "http://afm-platform.fe-k8s-afm.svc.cluster.local:8000")
    monkeypatch.setenv("AFM_IMPORT_MAX_BYTES", "8388608")

    return {
        "dir": tmp_path,
        "token": token,
        "key_file": key_file,
        "expires_file": expires_file,
        "key_spec": key_spec,
        "cluster": DEFAULT_CLUSTER,
        "key_name": DEFAULT_KEY_NAME,
    }


@pytest.fixture()
def outbound(monkeypatch):
    """Capture every request fe-signalloom sends through httpx.AsyncClient."""
    response_holder = {"handler": lambda req: httpx.Response(200, json={"status": "imported"})}

    class Captures(list):
        def set_response_handler(self, fn):
            response_holder["handler"] = fn

    sent = Captures()

    def handler(request: httpx.Request) -> httpx.Response:
        sent.append(request)
        return response_holder["handler"](request)

    real = httpx.AsyncClient

    class Capturing(real):  # type: ignore[misc, valid-type]
        def __init__(self, *args, **kwargs):
            kwargs["transport"] = httpx.MockTransport(handler)
            super().__init__(*args, **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", Capturing)
    return sent


def _valid_body(cluster_id: str = DEFAULT_CLUSTER) -> bytes:
    return json.dumps(
        {
            "id": cluster_id,
            "name": "Local Cluster",
            "rbac": {
                "subjects": [{"kind": "ServiceAccount", "name": "test-sa", "namespace": "default"}],
                "roles": [{"name": "test-role", "scope": "Cluster", "rules": [{"verbs": ["get"], "apiGroups": [""], "resources": ["pods"]}]}],
                "bindings": [{"name": "test-binding", "scope": "Cluster", "roleRef": "test-role", "subjects": [{"kind": "ServiceAccount", "name": "test-sa", "namespace": "default"}]}],
            },
        }
    ).encode("utf-8")


# ---------------------------------------------------------------------------
# T1 Refusal paths
# ---------------------------------------------------------------------------


def test_no_authorization_is_401_and_nothing_forwarded(key_env, outbound):
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body(),
        headers={"Content-Type": "application/json"},
    )
    assert resp.status_code == 401
    assert len(outbound) == 0


@pytest.mark.parametrize(
    "variant_kind",
    [
        "empty",
        "flipped_byte",
        "prefix",
        "suffix",
        "trailing_space",
        "trailing_newline",
        "basic_scheme",
        "lower_bearer",
        "duplicate_header",
    ],
)
def test_wrong_key_variants_are_401(key_env, outbound, variant_kind):
    token = key_env["token"]
    headers: list[tuple[str, str]] = []

    if variant_kind == "empty":
        headers = [("Authorization", "Bearer ")]
    elif variant_kind == "flipped_byte":
        flipped = token[:-1] + ("A" if token[-1] != "A" else "B")
        headers = [("Authorization", f"Bearer {flipped}")]
    elif variant_kind == "prefix":
        headers = [("Authorization", f"Bearer {token[:16]}")]
    elif variant_kind == "suffix":
        headers = [("Authorization", f"Bearer {token}extra")]
    elif variant_kind == "trailing_space":
        headers = [("Authorization", f"Bearer {token} ")]
    elif variant_kind == "trailing_newline":
        headers = [("Authorization", f"Bearer {token}\n")]
    elif variant_kind == "basic_scheme":
        b64 = base64.b64encode(token.encode("utf-8")).decode("utf-8")
        headers = [("Authorization", f"Basic {b64}")]
    elif variant_kind == "lower_bearer":
        headers = [("Authorization", f"bearer {token}")]
    elif variant_kind == "duplicate_header":
        headers = [
            ("Authorization", f"Bearer {token}"),
            ("Authorization", f"Bearer {token}"),
        ]

    client = TestClient(app, raise_server_exceptions=False)
    header_dict: dict[str, Any] = {"Content-Type": "application/json"}
    # Pass raw headers for duplicate header test
    resp = client.request(
        "POST",
        "/api/v1/afm/clusters/import",
        content=_valid_body(),
        headers=headers if variant_kind == "duplicate_header" else dict(headers),
    )
    assert resp.status_code == 401
    assert len(outbound) == 0


def test_other_scope_key_is_403_and_nothing_forwarded(key_env, outbound, monkeypatch):
    key_spec = [
        {
            "name": DEFAULT_KEY_NAME,
            "scopes": ["signals:read"],  # Not afm:import
            "cluster": DEFAULT_CLUSTER,
        }
    ]
    monkeypatch.setenv("AFM_IMPORT_KEYS", json.dumps(key_spec))

    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body(),
        headers={
            "Authorization": f"Bearer {key_env['token']}",
            "Content-Type": "application/json",
        },
    )
    assert resp.status_code == 403
    assert len(outbound) == 0


def test_importer_key_on_another_route_is_403(key_env, outbound):
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.get(
        "/api/signals/observations",
        headers={"Authorization": f"Bearer {key_env['token']}"},
    )
    assert resp.status_code in (401, 403)
    assert len(outbound) == 0


def test_body_cluster_id_mismatch_is_403(key_env, outbound):
    client = TestClient(app, raise_server_exceptions=False)
    body = _valid_body(cluster_id="unbound-cluster-id")
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=body,
        headers={
            "Authorization": f"Bearer {key_env['token']}",
            "Content-Type": "application/json",
        },
    )
    assert resp.status_code == 403
    assert len(outbound) == 0


@pytest.mark.parametrize(
    "kind,body_size,honest_header",
    [
        ("honest_content_length", 8388608 + 1, True),
        ("understated_content_length", 8388608 + 1, False),
        ("chunked_no_content_length", 8388608 + 1, None),
    ],
)
def test_oversized_body_is_413(key_env, outbound, kind, body_size, honest_header):
    # Construct a valid JSON prefix + padding + suffix
    prefix = b'{"id":"' + DEFAULT_CLUSTER.encode() + b'","p":"'
    pad_len = max(0, body_size - len(prefix) - 2)
    data = prefix + (b"A" * pad_len) + b'"}'
    assert len(data) >= body_size

    headers = {
        "Authorization": f"Bearer {key_env['token']}",
        "Content-Type": "application/json",
    }
    if honest_header is True:
        headers["Content-Length"] = str(len(data))
    elif honest_header is False:
        headers["Content-Length"] = "100"  # understated
    else:
        # None: no Content-Length (chunked simulation)
        pass

    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=data,
        headers=headers,
    )
    assert resp.status_code == 413
    assert len(outbound) == 0


@pytest.mark.parametrize(
    "error_kind,status_or_exc,expected_status",
    [
        ("status_500", httpx.Response(500, json={"error": "afm_internal_error"}), 502),
        ("timeout", httpx.TimeoutException("timeout"), 504),
        ("connection_error", httpx.ConnectError("connection refused"), 502),
    ],
)
def test_upstream_failure_is_not_success(key_env, outbound, error_kind, status_or_exc, expected_status):
    if isinstance(status_or_exc, httpx.Response):
        outbound.set_response_handler(lambda req: status_or_exc)
    else:
        def raise_exc(req):
            raise status_or_exc
        outbound.set_response_handler(raise_exc)

    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body(),
        headers={
            "Authorization": f"Bearer {key_env['token']}",
            "Content-Type": "application/json",
        },
    )
    assert resp.status_code == expected_status
    assert resp.status_code != 200
    assert len(outbound) == 1


@pytest.mark.parametrize(
    "defect_kind",
    [
        "missing_key_file",
        "empty_key_file",
        "whitespace_only_key_file",
        "short_key_file",
        "missing_expiry_file",
        "past_expiry",
        "over_90_day_expiry",
    ],
)
def test_missing_empty_or_blank_key_file_disables_route(key_env, outbound, caplog, defect_kind):
    token = key_env["token"]
    now = datetime.datetime.now(datetime.timezone.utc)

    if defect_kind == "missing_key_file":
        key_env["key_file"].unlink(missing_ok=True)
    elif defect_kind == "empty_key_file":
        key_env["key_file"].write_text("", encoding="utf-8")
    elif defect_kind == "whitespace_only_key_file":
        key_env["key_file"].write_text("   \n\t  \n", encoding="utf-8")
    elif defect_kind == "short_key_file":
        key_env["key_file"].write_text("short_key_less_than_32_bytes", encoding="utf-8")
    elif defect_kind == "missing_expiry_file":
        key_env["expires_file"].unlink(missing_ok=True)
    elif defect_kind == "past_expiry":
        past = now - datetime.timedelta(days=1)
        key_env["expires_file"].write_text(_rfc3339(past), encoding="utf-8")
    elif defect_kind == "over_90_day_expiry":
        far_future = now + datetime.timedelta(days=95)
        key_env["expires_file"].write_text(_rfc3339(far_future), encoding="utf-8")

    import logging
    caplog.set_level(logging.ERROR)

    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    assert resp.status_code == 503
    assert len(outbound) == 0
    # Must log an ERROR record mentioning the key name
    assert any(DEFAULT_KEY_NAME in rec.message for rec in caplog.records if rec.levelno >= logging.ERROR)


@pytest.mark.parametrize(
    "body_data",
    [
        b"{invalid-json",
        b"[1, 2, 3]",
        json.dumps({"name": "No ID", "rbac": {}}).encode("utf-8"),
        json.dumps({"id": 12345, "name": "Bad ID", "rbac": {}}).encode("utf-8"),
    ],
)
def test_non_json_or_idless_body_is_422(key_env, outbound, body_data):
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=body_data,
        headers={
            "Authorization": f"Bearer {key_env['token']}",
            "Content-Type": "application/json",
        },
    )
    assert resp.status_code == 422
    assert len(outbound) == 0


# ---------------------------------------------------------------------------
# T2 Accepted path, Secrecy contract, Constant-time compare
# ---------------------------------------------------------------------------


def test_valid_import_is_forwarded_once_with_the_bound_cluster(key_env, outbound):
    client = TestClient(app, raise_server_exceptions=False)
    body = _valid_body()
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=body,
        headers={
            "Authorization": f"Bearer {key_env['token']}",
            "Content-Type": "application/json",
        },
    )
    assert resp.status_code == 200
    assert len(outbound) == 1
    req = outbound[0]
    assert req.url.path == "/clusters/import"
    assert "authorization" not in {k.lower() for k in req.headers}
    forwarded_json = json.loads(req.content)
    assert forwarded_json["id"] == DEFAULT_CLUSTER


def test_key_value_never_logged_and_name_always_logged(key_env, outbound, caplog):
    import logging
    caplog.set_level(logging.DEBUG)

    token = key_env["token"]
    client = TestClient(app, raise_server_exceptions=False)

    # 1. Accepted request
    resp_ok = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    assert resp_ok.status_code == 200

    # 2. Refused request (cluster mismatch)
    resp_refused = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body(cluster_id="wrong-cluster"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    assert resp_refused.status_code == 403

    # Assertions over all logs, responses, and forwarded requests:
    all_log_text = "\n".join(rec.message + " " + str(rec.args) for rec in caplog.records)
    assert token not in all_log_text, "Bearer token value appeared in logs!"
    assert token not in resp_ok.text, "Bearer token value appeared in 200 response body!"
    assert token not in resp_refused.text, "Bearer token value appeared in 403 response body!"
    for req in outbound:
        assert token not in str(req.headers), "Bearer token value appeared in outbound headers!"

    # Key name must appear
    assert DEFAULT_KEY_NAME in all_log_text, f"Key name {DEFAULT_KEY_NAME} missing from logs"


def test_digest_compare_is_constant_time(key_env, outbound, monkeypatch):
    # Configure two keys: the request will match the first one
    token1 = key_env["token"]
    token2 = _make_key()

    key_file2 = key_env["dir"] / "afm-importer-secondary"
    key_file2.write_text(token2, encoding="utf-8")
    expires_file2 = key_env["dir"] / "afm-importer-secondary.expires"
    expires_file2.write_text(_rfc3339(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=90)), encoding="utf-8")

    key_spec = [
        {"name": DEFAULT_KEY_NAME, "scopes": ["afm:import"], "cluster": DEFAULT_CLUSTER},
        {"name": "afm-importer-secondary", "scopes": ["afm:import"], "cluster": "secondary-cluster"},
    ]
    monkeypatch.setenv("AFM_IMPORT_KEYS", json.dumps(key_spec))

    calls: list[tuple[bytes, bytes]] = []
    real_compare = hmac.compare_digest

    def spy_compare(a: bytes, b: bytes) -> bool:
        calls.append((a, b))
        return real_compare(a, b)

    monkeypatch.setattr(hmac, "compare_digest", spy_compare)

    client = TestClient(app, raise_server_exceptions=False)

    # 1. Valid request matching key #1
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body(),
        headers={
            "Authorization": f"Bearer {token1}",
            "Content-Type": "application/json",
        },
    )
    assert resp.status_code == 200
    # Must compare against ALL configured keys (2 calls), no early exit!
    assert len(calls) == 2, f"Expected 2 compare_digest calls, saw {len(calls)}"
    for a, b in calls:
        assert len(a) == 32 and len(b) == 32, "compare_digest arguments must be 32-byte SHA-256 digests"

    calls.clear()

    # 2. Invalid request with unknown token
    resp_bad = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body(),
        headers={
            "Authorization": f"Bearer {_make_key()}",
            "Content-Type": "application/json",
        },
    )
    assert resp_bad.status_code == 401
    assert len(calls) == 2


# ---------------------------------------------------------------------------
# T4 Operator path: the dashboard's own superadmin token
# ---------------------------------------------------------------------------


def test_superadmin_dex_token_imports_any_cluster_and_is_audited_as_the_operator(key_env, outbound, eap_jwt_env):
    """The RBAC importer panel sends the page's Dex bearer; a superadmin may import any cluster id."""
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body("signalloom-operator-import"),
        headers={**eap_bearer(EAP_OPERATOR), "Content-Type": "application/json"},
    )
    assert resp.status_code == 200, resp.text
    assert len(outbound) == 1
    assert outbound[0].url.path == "/clusters/import"
    assert "authorization" not in {k.lower() for k in outbound[0].headers}
    assert json.loads(outbound[0].content)["id"] == "signalloom-operator-import"


def test_non_superadmin_dex_token_is_403_and_never_retried_as_a_key(key_env, outbound, eap_jwt_env):
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body(),
        headers={**eap_bearer(EAP_ALICE), "Content-Type": "application/json"},
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "superadmin_required"
    assert outbound == []


def test_operator_path_needs_no_importer_key_configuration(outbound, eap_jwt_env, monkeypatch):
    """A dashboard import must not fail 503 on an estate whose importer key was never minted."""
    monkeypatch.delenv("AFM_IMPORT_KEYS", raising=False)
    monkeypatch.setenv("AFM_BASE_URL", "http://afm-platform.fe-k8s-afm.svc.cluster.local:8000")
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.post(
        "/api/v1/afm/clusters/import",
        content=_valid_body("signalloom-no-key"),
        headers={**eap_bearer(EAP_OPERATOR), "Content-Type": "application/json"},
    )
    assert resp.status_code == 200, resp.text
    assert len(outbound) == 1
