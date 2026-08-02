import http.client
import json
import threading
import unittest
from types import SimpleNamespace
from unittest import mock

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

    def test_unknown_route_is_404(self):
        self.assertEqual(404, self.request("GET", "/nope")[0])


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


if __name__ == "__main__":
    unittest.main()
