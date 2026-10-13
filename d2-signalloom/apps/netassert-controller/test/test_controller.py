import http.client
import io
import json
import socket
import threading
import unittest
from types import SimpleNamespace
from urllib import error
from unittest import mock

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import server
from server import ControllerHandler, ThreadingHTTPServer

FAKE_API_BASE = "https://kubernetes.test"


class ControllerServerTestCase(unittest.TestCase):
    """Shared in-process HTTP server plumbing for the controller handler."""

    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), ControllerHandler)
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()
        cls.port = cls.httpd.server_port

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.thread.join()

    def request(self, method, path, payload=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        data = json.dumps(payload) if payload is not None else None
        headers = {"Content-Type": "application/json"} if data else {}
        connection.request(method, path, data, headers)
        response = connection.getresponse()
        body = json.loads(response.read())
        connection.close()
        return response.status, body


class HealthTest(ControllerServerTestCase):
    def test_health_returns_ok(self):
        status, body = self.request("GET", "/health")
        self.assertEqual(200, status)
        self.assertEqual({"status": "ok"}, body)

    def test_healthz_returns_ok(self):
        status, body = self.request("GET", "/healthz")
        self.assertEqual(200, status)
        self.assertEqual({"status": "ok"}, body)

    def test_readyz_returns_ok(self):
        status, body = self.request("GET", "/readyz")
        self.assertEqual(200, status)
        self.assertEqual({"status": "ok"}, body)

    def test_livez_returns_ok(self):
        status, body = self.request("GET", "/livez")
        self.assertEqual(200, status)
        self.assertEqual({"status": "ok"}, body)

    def test_malformed_content_length_drains_safely(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        connection.request("GET", "/health", headers={"Content-Length": "invalid-len"})
        response = connection.getresponse()
        self.assertEqual(200, response.status)
        connection.close()

    def test_negative_content_length_drains_safely(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        connection.request("GET", "/health", headers={"Content-Length": "-5"})
        response = connection.getresponse()
        self.assertEqual(200, response.status)
        connection.close()

    def test_unknown_route_is_404(self):
        self.assertEqual(404, self.request("GET", "/nope")[0])

    def test_health_head_probes(self):
        for path in ("/health", "/healthz", "/readyz", "/livez"):
            connection = http.client.HTTPConnection("127.0.0.1", self.port)
            connection.request("HEAD", path)
            response = connection.getresponse()
            self.assertEqual(200, response.status)
            body = response.read()
            self.assertEqual(b"", body)
            self.assertEqual("15", response.getheader("Content-Length"))
            self.assertEqual("application/json", response.getheader("Content-Type"))
            connection.close()

    def test_unknown_route_head_is_404_empty_body(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        connection.request("HEAD", "/nope")
        response = connection.getresponse()
        self.assertEqual(404, response.status)
        self.assertEqual(b"", response.read())
        self.assertEqual("application/json", response.getheader("Content-Type"))
        self.assertTrue(int(response.getheader("Content-Length")) > 0)
        connection.close()

    def test_health_head_method_not_allowed_returns_405_and_empty_body(self):
        for path in ("/health", "/healthz", "/readyz", "/livez"):
            for method in ("POST", "PUT", "DELETE", "PATCH"):
                connection = http.client.HTTPConnection("127.0.0.1", self.port)
                connection.request(method, path)
                response = connection.getresponse()
                self.assertEqual(405, response.status)
                self.assertEqual("GET, HEAD, OPTIONS", response.getheader("Allow"))
                self.assertEqual("application/json", response.getheader("Content-Type"))
                body = json.loads(response.read())
                self.assertEqual({"error": "method not allowed"}, body)
                connection.close()

    def test_health_options_returns_204_and_allow_header(self):
        for path in ("/health", "/healthz", "/readyz", "/livez"):
            connection = http.client.HTTPConnection("127.0.0.1", self.port)
            connection.request("OPTIONS", path)
            response = connection.getresponse()
            self.assertEqual(204, response.status)
            self.assertEqual("GET, HEAD, OPTIONS", response.getheader("Allow"))
            self.assertIsNone(response.getheader("Content-Type"))
            self.assertIsNone(response.getheader("Content-Length"))
            self.assertEqual(b"", response.read())
            connection.close()

    def test_unsupported_method_returns_405_and_route_specific_allow_header(self):
        # 1. /health should only advertise GET, HEAD, OPTIONS
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        connection.request("NONSTANDARD", "/health")
        response = connection.getresponse()
        self.assertEqual(405, response.status)
        self.assertEqual("GET, HEAD, OPTIONS", response.getheader("Allow"))
        self.assertEqual("application/json", response.getheader("Content-Type"))
        body = json.loads(response.read())
        self.assertEqual({"error": "method not allowed"}, body)
        connection.close()

        # 2. /scan should only advertise POST, DELETE, OPTIONS
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        connection.request("NONSTANDARD", "/scan")
        response = connection.getresponse()
        self.assertEqual(405, response.status)
        self.assertEqual("POST, DELETE, OPTIONS", response.getheader("Allow"))
        self.assertEqual("application/json", response.getheader("Content-Type"))
        body = json.loads(response.read())
        self.assertEqual({"error": "method not allowed"}, body)
        connection.close()

        # 3. Nonexistent route returns 404
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        connection.request("NONSTANDARD", "/nope")
        response = connection.getresponse()
        self.assertEqual(404, response.status)
        self.assertEqual("application/json", response.getheader("Content-Type"))
        body = json.loads(response.read())
        self.assertEqual({"error": "unknown route"}, body)
        connection.close()

    def test_chunked_body_drains_safely_on_options(self):
        s = socket.create_connection(("127.0.0.1", self.port))
        raw_req = (
            b"OPTIONS /health HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n"
            b"5\r\nhello\r\n0\r\n\r\n"
        )
        s.sendall(raw_req)
        s.settimeout(2.0)
        data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\r\n\r\n" in data:
                break
        s.close()
        self.assertTrue(data.startswith(b"HTTP/1.0 204 No Content") or data.startswith(b"HTTP/1.1 204 No Content"))
        self.assertIn(b"Allow: GET, HEAD, OPTIONS", data)
        self.assertNotIn(b"Content-Length", data)

    def test_oversized_body_closes_connection(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        connection.request("OPTIONS", "/health", headers={"Content-Length": "2000000"})
        response = connection.getresponse()
        self.assertEqual(204, response.status)
        self.assertEqual("close", response.getheader("Connection"))
        connection.close()

    def test_json_none_payload_on_200_emits_content_length(self):
        class DummyHandler:
            command = "GET"
            def send_response(self, code): self.code = code
            def send_header(self, k, v): self.headers[k] = v
            def end_headers(self): pass
            def __init__(self):
                self.headers = {}
                self.wfile = io.BytesIO()
        h = DummyHandler()
        server.ControllerHandler._json(h, 200, None)
        self.assertEqual(200, h.code)
        self.assertEqual("application/json", h.headers.get("Content-Type"))
        self.assertEqual("2", h.headers.get("Content-Length"))
        self.assertEqual(b"{}", h.wfile.getvalue())

    def test_threading_http_server_sets_allow_reuse_address(self):
        self.assertTrue(ThreadingHTTPServer.allow_reuse_address)



class ScanTest(ControllerServerTestCase):
    """/scan owns the exact create/delete/conflict logic that used to live in
    fake-integration-proxy's _handle_network_tests_scan — this is now the
    only place in the system holding the token capable of it."""

    def install(self, *, job=None, get_job_calls=None, created=None, deleted=None):
        get_job_calls = get_job_calls if get_job_calls is not None else []
        created = created if created is not None else []
        deleted = deleted if deleted is not None else []

        def fake_get_job(base_url, token, context, namespace, name):
            get_job_calls.append((namespace, name))
            return job

        def fake_create_job(base_url, token, context, namespace, manifest):
            created.append((namespace, manifest))

        def fake_delete_job(base_url, token, context, namespace, name):
            deleted.append((namespace, name))

        patches = [
            mock.patch.object(server, "_read_service_account_token", lambda *a, **k: "fake-token"),
            mock.patch.object(server, "_kubernetes_ssl_context", lambda *a, **k: None),
            mock.patch.object(server, "_kubernetes_api_base", lambda: FAKE_API_BASE),
            mock.patch.object(server, "_get_kubernetes_job", fake_get_job),
            mock.patch.object(server, "_create_kubernetes_job", fake_create_job),
            mock.patch.object(server, "_delete_kubernetes_job", fake_delete_job),
            mock.patch.object(server, "time", mock.Mock(sleep=lambda *_: None)),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        return SimpleNamespace(get_job_calls=get_job_calls, created=created, deleted=deleted)

    def test_scan_creates_the_fixed_job_when_none_exists(self):
        state = self.install(job=None)
        status, body = self.request("POST", "/scan")
        self.assertEqual(202, status)
        self.assertEqual("started", body["status"])
        self.assertEqual(1, len(state.created))
        namespace, manifest = state.created[0]
        self.assertEqual(server.NETASSERT_JOB_NAMESPACE, namespace)
        self.assertEqual(server.NETASSERT_JOB_NAME, manifest["metadata"]["name"])
        self.assertEqual(300, manifest["spec"]["activeDeadlineSeconds"])
        self.assertEqual(0, len(state.deleted))

    def test_scan_ignores_the_request_body_entirely(self):
        """The Job spec must be identical regardless of what a caller sends —
        this is what stops the endpoint becoming an arbitrary-target probe,
        now enforced at the one place capable of creating the Job."""
        state = self.install(job=None)
        self.request("POST", "/scan", {"target": "10.0.0.1", "namespace": "kube-system"})
        manifest_with_body = state.created[0][1]
        state.created.clear()
        self.request("POST", "/scan")
        manifest_without_body = state.created[0][1]
        self.assertEqual(manifest_with_body, manifest_without_body)
        self.assertNotIn("10.0.0.1", json.dumps(manifest_with_body))

    def test_scan_rejects_a_second_run_while_one_is_active(self):
        job = {"status": {"active": 1}}
        state = self.install(job=job)
        status, body = self.request("POST", "/scan")
        self.assertEqual(409, status)
        self.assertIn("already running", body["error"])
        self.assertEqual(0, len(state.created))
        self.assertEqual(0, len(state.deleted))

    def test_scan_deletes_a_finished_job_before_recreating_it(self):
        job = {"status": {"succeeded": 1, "conditions": [{"type": "Complete", "status": "True"}]}}
        calls = []

        def fake_get_job(base_url, token, context, namespace, name):
            calls.append(1)
            return job if len(calls) == 1 else None

        state = self.install(job=None)
        override = mock.patch.object(server, "_get_kubernetes_job", fake_get_job)
        override.start()
        self.addCleanup(override.stop)

        status, _ = self.request("POST", "/scan")
        self.assertEqual(202, status)
        self.assertEqual(1, len(state.deleted))
        self.assertEqual((server.NETASSERT_JOB_NAMESPACE, server.NETASSERT_JOB_NAME), state.deleted[0])
        self.assertEqual(1, len(state.created))

    def test_scan_reports_bad_gateway_when_the_api_is_unreachable(self):
        patches = [
            mock.patch.object(server, "_read_service_account_token", mock.Mock(side_effect=OSError("no token"))),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        status, body = self.request("POST", "/scan")
        self.assertEqual(502, status)
        self.assertIn("no token", body["error"])

    def test_scan_reports_bad_gateway_when_job_lookup_fails(self):
        state = self.install(job=None)
        lookup = mock.patch.object(
            server, "_get_kubernetes_job", mock.Mock(side_effect=error.URLError("api down"))
        )
        lookup.start()
        self.addCleanup(lookup.stop)
        status, body = self.request("POST", "/scan")
        self.assertEqual(502, status)
        self.assertIn("failed to inspect scan", body["error"])
        self.assertEqual([], state.created)

    def test_fixed_job_preserves_tap_and_netassert_exit_status(self):
        container = server._netassert_job_manifest()["spec"]["template"]["spec"]["containers"][0]
        shell = container["command"][2]
        self.assertIn(server.NETASSERT_TAP_MARKER, shell)
        self.assertIn("cat /work/results.tap", shell)
        self.assertIn("/usr/local/bin/validate-tap.sh /work/results.tap", shell)
        self.assertIn("status=2", shell)
        self.assertIn("exit ${status}", shell)
        self.assertNotIn("|| true", shell)
        self.assertLess(shell.index("netassert run"), shell.index("validate-tap.sh"))
        self.assertLess(shell.index("validate-tap.sh"), shell.index("exit ${status}"))

    def test_fixed_job_distinguishes_assertion_failure_from_invalid_execution(self):
        shell = server._netassert_job_manifest()["spec"]["template"]["spec"]["containers"][0]["command"][2]
        self.assertIn("|| status=$?", shell)
        self.assertIn("if ! /usr/local/bin/validate-tap.sh", shell)
        self.assertIn("status=2", shell)

    def test_fixed_job_pins_ephemeral_runner_images_by_digest(self):
        shell = server._netassert_job_manifest()["spec"]["template"]["spec"]["containers"][0]["command"][2]
        self.assertIn(f"-c '{server.NETASSERT_SCANNER_IMAGE}'", shell)
        self.assertIn(f"-i '{server.NETASSERT_SNIFFER_IMAGE}'", shell)
        self.assertRegex(server.NETASSERT_SCANNER_IMAGE, r"@sha256:[0-9a-f]{64}$")
        self.assertRegex(server.NETASSERT_SNIFFER_IMAGE, r"@sha256:[0-9a-f]{64}$")

    def test_scan_delete_aborts_active_or_completed_job(self):
        job = {"status": {"active": 1}}
        state = self.install(job=job)
        status, body = self.request("DELETE", "/scan")
        self.assertEqual(200, status)
        self.assertEqual("deleted", body["status"])
        self.assertEqual(server.NETASSERT_JOB_NAME, body["job"])
        self.assertEqual(1, len(state.deleted))
        self.assertEqual((server.NETASSERT_JOB_NAMESPACE, server.NETASSERT_JOB_NAME), state.deleted[0])

    def test_scan_delete_returns_404_when_no_job_exists(self):
        state = self.install(job=None)
        status, body = self.request("DELETE", "/scan")
        self.assertEqual(404, status)
        self.assertIn("no scan found", body["error"])
        self.assertEqual(0, len(state.deleted))

    def test_scan_delete_reports_bad_gateway_on_k8s_failure(self):
        state = self.install(job={"status": {"active": 1}})
        del_patch = mock.patch.object(
            server, "_delete_kubernetes_job", mock.Mock(side_effect=error.URLError("deletion failed"))
        )
        del_patch.start()
        self.addCleanup(del_patch.stop)
        status, body = self.request("DELETE", "/scan")
        self.assertEqual(502, status)
        self.assertIn("could not delete scan", body["error"])

    def test_scan_method_not_allowed_returns_405_and_allow_header(self):
        for method in ("GET", "PUT", "PATCH"):
            connection = http.client.HTTPConnection("127.0.0.1", self.port)
            connection.request(method, "/scan")
            response = connection.getresponse()
            self.assertEqual(405, response.status)
            self.assertEqual("POST, DELETE, OPTIONS", response.getheader("Allow"))
            self.assertEqual("application/json", response.getheader("Content-Type"))
            body = json.loads(response.read())
            self.assertEqual({"error": "method not allowed"}, body)
            connection.close()

    def test_scan_head_returns_405_and_allow_header_and_empty_body(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        connection.request("HEAD", "/scan")
        response = connection.getresponse()
        self.assertEqual(405, response.status)
        self.assertEqual("POST, DELETE, OPTIONS", response.getheader("Allow"))
        self.assertEqual("application/json", response.getheader("Content-Type"))
        self.assertEqual(b"", response.read())
        connection.close()

    def test_scan_options_returns_204_and_allow_header(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        connection.request("OPTIONS", "/scan")
        response = connection.getresponse()
        self.assertEqual(204, response.status)
        self.assertEqual("POST, DELETE, OPTIONS", response.getheader("Allow"))
        self.assertIsNone(response.getheader("Content-Type"))
        self.assertIsNone(response.getheader("Content-Length"))
        self.assertEqual(b"", response.read())
        connection.close()

    def test_server_allows_address_reuse(self):
        self.assertTrue(ThreadingHTTPServer.allow_reuse_address)
        self.assertTrue(self.httpd.allow_reuse_address)


if __name__ == "__main__":

    unittest.main()
