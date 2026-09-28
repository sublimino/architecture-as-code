import json
import os
import stat
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

import environment_teardown_adapters as adapters
from environment_teardown_adapters import (
    ConfiguredTeardownExecutor,
    FailClosedExecutor,
    KeySpireAdapter,
    KubernetesNamespaceStorageClient,
    MeshAdapter,
    OpenBaoHTTPClient,
    SpireCLIClient,
    TailscaleAdminAPIClient,
)
from environment_teardown_contract import (
    StageRequest,
    StageResult,
    TeardownAuthorizationError,
    TeardownSecurityError,
    TeardownStage,
)


def request(seconds=2):
    return StageRequest("0123abcd", "review-regression", time.monotonic() + seconds)


def executable(tmp_path: Path, body: str) -> str:
    path = tmp_path / "provider"
    path.write_text("#!/usr/bin/env python3\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return str(path)


def test_namespace_forbidden_is_not_misreported_as_absent(tmp_path):
    binary = executable(tmp_path, "import sys; print('Forbidden', file=sys.stderr); sys.exit(1)\n")
    client = KubernetesNamespaceStorageClient(binary, "kubernetes-pv")
    with pytest.raises(Exception, match="namespace_lookup_failed"):
        client.namespace_exists("eap-0123abcd", 1)


def test_namespace_absence_requires_valid_empty_ignore_not_found_response(tmp_path):
    binary = executable(tmp_path, "print('')\n")
    client = KubernetesNamespaceStorageClient(binary, "kubernetes-pv")
    assert client.namespace_exists("eap-0123abcd", 1) is False


def test_tailscale_missing_devices_collection_is_rejected(monkeypatch):
    client = TailscaleAdminAPIClient("https://api.tailscale.com", "example", "secret")
    monkeypatch.setattr(client, "_request", lambda *args, **kwargs: {})
    with pytest.raises(Exception, match="invalid_tailscale_inventory"):
        client.list_nodes(1)


def test_spire_missing_entries_collection_is_rejected(tmp_path):
    binary = executable(tmp_path, "print('{}')\n")
    client = SpireCLIClient(binary, "/tmp/spire.sock")
    with pytest.raises(Exception, match="invalid_spire_inventory"):
        client.list_entries(1)


def test_mesh_refuses_same_name_device_without_authoritative_ownership():
    class Client:
        deleted = []

        def list_nodes(self, timeout):
            return [{"id": "unowned", "hostname": "sl-eap-0123abcd", "tags": []}]

        def delete_node(self, node_id, timeout):
            self.deleted.append(node_id)

    client = Client()
    result = MeshAdapter(client, ownership={}).execute(request())
    assert not result.success and result.detail == "ownership_inventory_missing"
    assert client.deleted == []


def test_mesh_refuses_unowned_same_name_collision():
    class Client:
        deleted = []

        def list_nodes(self, timeout):
            return [{"id": "other", "hostname": "sl-eap-0123abcd", "tags": ["tag:eap-0123abcd"]}]

        def delete_node(self, node_id, timeout):
            self.deleted.append(node_id)

    ownership = {"0123abcd": {"device_ids": ["owned"], "tag": "tag:eap-0123abcd"}}
    client = Client()
    result = MeshAdapter(client, ownership=ownership).execute(request())
    assert not result.success and result.detail == "mesh_ownership_collision"
    assert client.deleted == []


def test_spiffe_matcher_accepts_object_form_and_rejects_substring_collision():
    entries = [
        {"id": "owned", "spiffe_id": {"trust_domain": "signalloom.demo", "path": "/ns/eap-0123abcd/sa/app"}},
        {"id": "evil", "spiffe_id": "spiffe://evil/ns/eap-0123abcd/sa/app"},
        {"id": "substring", "spiffe_id": "spiffe://signalloom.demo/x/ns/eap-0123abcd/sa/app"},
    ]
    matched = adapters.KeySpireAdapter._tenant_entries(entries, "0123abcd")
    assert [entry["id"] for entry in matched] == ["owned"]


def test_openbao_requires_https():
    with pytest.raises(ValueError, match="HTTPS"):
        adapters.OpenBaoHTTPClient("http://openbao", "secret", "ciphertext")


def test_kubernetes_pv_observation_never_claims_storage_erasure(tmp_path):
    binary = executable(tmp_path, "import json; print(json.dumps({'items':[]}))\n")
    proof = KubernetesNamespaceStorageClient(binary, "kubernetes-pv").storage_absence_proof("eap-0123abcd", 1)
    assert proof["verified"] is False
    assert proof["blocker"] == "durable_storage_erasure_unproved"


def test_raw_provider_exception_is_sanitized():
    class Exploding:
        def execute(self, stage_request):
            raise RuntimeError("X-Vault-Token=super-secret")

        def verify(self, stage_request):
            raise RuntimeError("Authorization: secret")

    executor = ConfiguredTeardownExecutor({TeardownStage.ROUTE: Exploding()})
    assert executor.execute(TeardownStage.ROUTE, request()).detail == "provider_failed"
    assert executor.verify(TeardownStage.ROUTE, request()).detail == "provider_failed"


def test_verify_is_read_only_and_fail_closed_executor_supports_it():
    class ReadOnly:
        executions = 0
        verifications = 0

        def execute(self, stage_request):
            self.executions += 1
            return StageResult(TeardownStage.ROUTE, True)

        def verify(self, stage_request):
            self.verifications += 1
            return StageResult(TeardownStage.ROUTE, True, "verified")

    adapter = ReadOnly()
    executor = ConfiguredTeardownExecutor({TeardownStage.ROUTE: adapter})
    assert executor.verify(TeardownStage.ROUTE, request()).success
    assert adapter.executions == 0 and adapter.verifications == 1
    assert not FailClosedExecutor().verify(TeardownStage.ROUTE, request()).success


def test_bounded_http_transport_stops_slow_drip_body():
    class SlowDrip(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            for _ in range(100):
                self.wfile.write(b"x")
                self.wfile.flush()
                time.sleep(0.05)

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), SlowDrip)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        transport = adapters.BoundedHTTPTransport(allow_http_loopback=True, max_body_bytes=64)
        started = time.monotonic()
        with pytest.raises(Exception, match="http_deadline_exceeded"):
            transport.request("GET", f"http://127.0.0.1:{server.server_port}/", {}, None, 0.2)
        assert time.monotonic() - started < 1
    finally:
        server.shutdown()


def test_redirect_is_rejected_before_secret_header_can_be_forwarded():
    class Redirect(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(302)
            self.send_header("Location", "https://attacker.invalid/")
            self.end_headers()

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Redirect)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        transport = adapters.BoundedHTTPTransport(allow_http_loopback=True)
        with pytest.raises(Exception, match="http_redirect_rejected"):
            transport.request(
                "GET",
                f"http://127.0.0.1:{server.server_port}/",
                {"Authorization": "secret"},
                None,
                1,
            )
    finally:
        server.shutdown()


def test_openbao_authorization_failure_fails_stage_cleanly():
    class ForbiddenBao:
        def delete_tenant_material(self, customer_hash, timeout):
            raise TeardownAuthorizationError("openbao_authorization_failed")

        def key_exists(self, customer_hash, timeout):
            raise TeardownAuthorizationError("openbao_authorization_failed")

        def secret_exists(self, customer_hash, timeout):
            raise TeardownAuthorizationError("openbao_authorization_failed")

        def decrypt_fails(self, customer_hash, timeout):
            raise TeardownAuthorizationError("openbao_authorization_failed")

    class EmptySpire:
        def list_entries(self, timeout):
            return []

        def delete_entry(self, entry_id, timeout):
            pass

    adapter = KeySpireAdapter(ForbiddenBao(), EmptySpire())
    exec_result = adapter.execute(request())
    assert not exec_result.success
    assert exec_result.detail == "openbao_authorization_failed"

    verify_result = adapter.verify(request())
    assert not verify_result.success
    assert verify_result.detail == "openbao_authorization_failed"


def test_openbao_server_error_fails_stage_cleanly():
    class ErrorBao:
        def delete_tenant_material(self, customer_hash, timeout):
            raise TeardownSecurityError("OpenBao server error: HTTP 500")

        def key_exists(self, customer_hash, timeout):
            raise TeardownSecurityError("OpenBao server error: HTTP 500")

        def secret_exists(self, customer_hash, timeout):
            raise TeardownSecurityError("OpenBao server error: HTTP 500")

        def decrypt_fails(self, customer_hash, timeout):
            raise TeardownSecurityError("OpenBao server error: HTTP 500")

    class EmptySpire:
        def list_entries(self, timeout):
            return []

        def delete_entry(self, entry_id, timeout):
            pass

    adapter = KeySpireAdapter(ErrorBao(), EmptySpire())
    exec_result = adapter.execute(request())
    assert not exec_result.success
    assert "HTTP 500" in exec_result.detail


def test_openbao_http_client_status_codes(monkeypatch):
    client = OpenBaoHTTPClient("https://openbao.local", "token", "ct")

    # 404 on key_exists means key is absent (False)
    monkeypatch.setattr(client, "_request", lambda m, p, t, b=None: (404, {}))
    assert client.key_exists("0123abcd", 1) is False
    assert client.secret_exists("0123abcd", 1) is False
    assert client.decrypt_fails("0123abcd", 1) is True

    # 403 raises TeardownAuthorizationError
    monkeypatch.setattr(client, "_request", lambda m, p, t, b=None: (403, {}))
    with pytest.raises(TeardownAuthorizationError):
        client.key_exists("0123abcd", 1)
    with pytest.raises(TeardownAuthorizationError):
        client.secret_exists("0123abcd", 1)
    with pytest.raises(TeardownAuthorizationError):
        client.decrypt_fails("0123abcd", 1)
    with pytest.raises(TeardownAuthorizationError):
        client.delete_tenant_material("0123abcd", 1)

    # 500 raises TeardownSecurityError
    monkeypatch.setattr(client, "_request", lambda m, p, t, b=None: (500, {}))
    with pytest.raises(TeardownSecurityError):
        client.key_exists("0123abcd", 1)
    with pytest.raises(TeardownSecurityError):
        client.secret_exists("0123abcd", 1)
    with pytest.raises(TeardownSecurityError):
        client.decrypt_fails("0123abcd", 1)
    with pytest.raises(TeardownSecurityError):
        client.delete_tenant_material("0123abcd", 1)
