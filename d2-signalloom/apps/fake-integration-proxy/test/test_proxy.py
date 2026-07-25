import http.client
import json
import os
import threading
import unittest

os.environ["SIGNALLOOM_DEMO_PROFILE"] = "demo"

from server import ProxyHandler, ThreadingHTTPServer


class ProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), ProxyHandler)
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()
        cls.port = cls.httpd.server_port

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.thread.join()

    def setUp(self):
        self.request("DELETE", "/_test/requests")

    def request(self, method, path, payload=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port)
        data = json.dumps(payload) if payload is not None else None
        request_headers = headers or {}
        if data:
            request_headers.setdefault("Content-Type", "application/json")
        connection.request(method, path, data, request_headers)
        response = connection.getresponse()
        body = json.loads(response.read())
        connection.close()
        return response.status, body

    def test_all_route_groups_return_deterministic_fixtures(self):
        for path in ("/llm/assistants", "/crm/contacts", "/notification/messages", "/outbound-reporting/reports"):
            status, first = self.request("POST", path, {"name": "demo"})
            self.assertEqual(200, status)
            self.assertEqual((status, first), self.request("POST", path, {"name": "demo"}))

    def test_capture_redacts_secrets_and_excludes_authorization(self):
        self.request("POST", "/llm/assistants", {"token": "never-store", "openai_api_key": "never-store", "nested": {"password": "never-store"}}, {
            "Authorization": "Bearer never-store", "X-Api-Key": "never-store", "X-Request-ID": "trace-1"})
        status, captured = self.request("GET", "/_test/requests")
        self.assertEqual(200, status)
        request = captured["requests"][0]
        self.assertEqual("[REDACTED]", request["body"]["token"])
        self.assertEqual("[REDACTED]", request["body"]["openai_api_key"])
        self.assertEqual("[REDACTED]", request["body"]["nested"]["password"])
        self.assertEqual("trace-1", request["headers"]["x-request-id"])
        self.assertNotIn("authorization", request["headers"])
        self.assertNotIn("x-api-key", request["headers"])
        self.assertNotIn("never-store", json.dumps(captured))

    def test_reset_mutation_and_unknown_routes(self):
        self.request("PUT", "/_test/fixtures/crm/customer", {"id": "customer-42"})
        self.assertEqual((200, {"id": "customer-42"}), self.request("POST", "/crm/customer", {}))
        self.request("POST", "/crm/customer", {})
        self.assertEqual((200, {"requests": []}), self.request("DELETE", "/_test/requests"))
        self.assertEqual(404, self.request("GET", "/unrecognised")[0])

    def test_control_api_is_not_exposed_outside_demo(self):
        old = os.environ.pop("SIGNALLOOM_DEMO_PROFILE")
        try:
            self.assertEqual(404, self.request("GET", "/_test/fixtures")[0])
        finally:
            os.environ["SIGNALLOOM_DEMO_PROFILE"] = old


if __name__ == "__main__":
    unittest.main()
