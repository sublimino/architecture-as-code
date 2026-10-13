#!/usr/bin/env python3
"""Contract tests for test/fixtures/user-surface-gate/stub-surface-server.py.

Verifies:
1. GET /health, /healthz, /readyz return 200 with valid Content-Length and body.
2. HEAD /health, /healthz, /readyz return 200 with matching Content-Length and empty body.
3. Unsupported methods return 405 Method Not Allowed with Allow header.
4. send_error formats JSON errors and suppresses response body on HEAD.
5. 501 Not Implemented maps to 405 with Allow header.
"""

from __future__ import annotations

import importlib.util
import json
import os
import socket
import threading
import unittest
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location(
    "stub_surface_server",
    os.path.join(os.path.dirname(__file__), "stub-surface-server.py"),
)
stub_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stub_module)
Handler = stub_module.Handler
ReusableThreadingHTTPServer = stub_module.ReusableThreadingHTTPServer


class StubSurfaceServerContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        stub_module.SCENARIO = {
            "testdemo": {"status": "healthy"},
        }
        cls.server = ReusableThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever)
        cls.thread.daemon = True
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2.0)

    def test_probes_get_and_head_parity(self):
        for path in ("/health", "/healthz", "/readyz"):
            url = f"http://127.0.0.1:{self.port}{path}"
            with urllib.request.urlopen(url) as resp:
                self.assertEqual(resp.status, 200)
                body = resp.read()
                self.assertEqual(json.loads(body.decode()), {"status": "ok"})
                self.assertEqual(resp.headers.get("Content-Length"), str(len(body)))

            head_req = urllib.request.Request(url, method="HEAD")
            with urllib.request.urlopen(head_req) as head_resp:
                self.assertEqual(head_resp.status, 200)
                self.assertEqual(head_resp.read(), b"")
                self.assertEqual(head_resp.headers.get("Content-Length"), str(len(body)))

    def test_unsupported_methods_return_405_with_allow(self):
        url = f"http://127.0.0.1:{self.port}/health"
        for method in ("PUT", "DELETE", "PATCH", "OPTIONS"):
            req = urllib.request.Request(url, data=b"{}", method=method)
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(req)
            self.assertEqual(ctx.exception.code, 405)
            self.assertEqual(ctx.exception.headers.get("Allow"), "GET, HEAD")
            self.assertEqual(ctx.exception.headers.get("Content-Type"), "application/json")
            err_body = ctx.exception.read()
            self.assertGreater(len(err_body), 0)
            self.assertEqual(ctx.exception.headers.get("Content-Length"), str(len(err_body)))
            ctx.exception.close()

    def test_dex_token_unsupported_method_returns_405_post_allow(self):
        url = f"http://127.0.0.1:{self.port}/dex/token"
        req = urllib.request.Request(url, method="GET")
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 405)
        self.assertEqual(ctx.exception.headers.get("Allow"), "POST")
        ctx.exception.close()

    def test_chunked_post_decodes_correctly(self):
        s = socket.create_connection(("127.0.0.1", self.port))
        payload = b'{"step": 1}'
        chunk = f"{len(payload):x}\r\n".encode() + payload + b"\r\n0\r\n\r\n"
        raw_req = (
            b"POST /api/demo/testdemo/runs HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Authorization: Bearer stub-id-token-for-gate-tests\r\n"
            b"Transfer-Encoding: chunked\r\n"
            b"Content-Type: application/json\r\n\r\n" + chunk
        )
        s.sendall(raw_req)
        s.settimeout(2.0)
        data = b""
        while True:
            recv = s.recv(4096)
            if not recv:
                break
            data += recv
            if b"\r\n\r\n" in data:
                break
        s.close()
        self.assertTrue(data.startswith(b"HTTP/1.1 202 Accepted") or data.startswith(b"HTTP/1.0 202 Accepted"))

    def test_malformed_chunk_returns_400_and_closes_connection(self):
        s = socket.create_connection(("127.0.0.1", self.port))
        raw_req = (
            b"POST /api/demo/testdemo/runs HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Authorization: Bearer stub-id-token-for-gate-tests\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n"
            b"ZZ\r\ninvalid\r\n0\r\n\r\n"
        )
        s.sendall(raw_req)
        s.settimeout(2.0)
        data = b""
        while True:
            recv = s.recv(4096)
            if not recv:
                break
            data += recv
            if b"\r\n\r\n" in data:
                break
        s.close()
        self.assertTrue(data.startswith(b"HTTP/1.1 400 Bad Request") or data.startswith(b"HTTP/1.0 400 Bad Request"))
        self.assertIn(b"Connection: close", data)

    def test_negative_content_length_returns_400_and_closes_connection(self):
        s = socket.create_connection(("127.0.0.1", self.port))
        raw_req = (
            b"POST /api/demo/testdemo/runs HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Authorization: Bearer stub-id-token-for-gate-tests\r\n"
            b"Content-Length: -5\r\n\r\n"
        )
        s.sendall(raw_req)
        s.settimeout(2.0)
        data = b""
        while True:
            recv = s.recv(4096)
            if not recv:
                break
            data += recv
            if b"\r\n\r\n" in data:
                break
        s.close()
        self.assertTrue(data.startswith(b"HTTP/1.1 400 Bad Request") or data.startswith(b"HTTP/1.0 400 Bad Request"))
        self.assertIn(b"Connection: close", data)

    def test_chunked_premature_eof_returns_400_and_closes_connection(self):
        s = socket.create_connection(("127.0.0.1", self.port))
        payload = b'{"step": 1}'
        # Chunk without terminal 0\r\n\r\n
        raw_req = (
            b"POST /api/demo/testdemo/runs HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Authorization: Bearer stub-id-token-for-gate-tests\r\n"
            b"Transfer-Encoding: chunked\r\n"
            b"Content-Type: application/json\r\n\r\n"
            + f"{len(payload):x}\r\n".encode()
            + payload
            + b"\r\n"
        )
        s.sendall(raw_req)
        s.shutdown(socket.SHUT_WR)
        s.settimeout(2.0)
        data = b""
        while True:
            recv = s.recv(4096)
            if not recv:
                break
            data += recv
            if b"\r\n\r\n" in data:
                break
        s.close()
        self.assertTrue(data.startswith(b"HTTP/1.1 400 Bad Request") or data.startswith(b"HTTP/1.0 400 Bad Request"))
        self.assertIn(b"Connection: close", data)

    def test_conflicting_transfer_encoding_and_content_length_returns_400(self):
        s = socket.create_connection(("127.0.0.1", self.port))
        payload = b'{"step": 1}'
        chunk = f"{len(payload):x}\r\n".encode() + payload + b"\r\n0\r\n\r\n"
        raw_req = (
            b"POST /api/demo/testdemo/runs HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Authorization: Bearer stub-id-token-for-gate-tests\r\n"
            b"Transfer-Encoding: chunked\r\n"
            b"Content-Length: 11\r\n"
            b"Content-Type: application/json\r\n\r\n" + chunk
        )
        s.sendall(raw_req)
        s.settimeout(2.0)
        data = b""
        while True:
            recv = s.recv(4096)
            if not recv:
                break
            data += recv
            if b"\r\n\r\n" in data:
                break
        s.close()
        self.assertTrue(data.startswith(b"HTTP/1.1 400 Bad Request") or data.startswith(b"HTTP/1.0 400 Bad Request"))
        self.assertIn(b"Connection: close", data)

    def test_send_error_override_direct(self):
        class MockHandler:
            command = "HEAD"
            path = "/health"
            responses = {400: ("Bad Request", "Detail"), 404: ("Not Found", "Detail"), 405: ("Method Not Allowed", ""), 501: ("Not Implemented", "")}

            def __init__(self):
                self.headers_out = {}
                self.status_code = None
                self.body = bytearray()

            def _allowed_methods_for_path(self, path):
                return Handler._allowed_methods_for_path(self, path)

            def _send(self, code, payload, extra_headers=None):
                return Handler._send(self, code, payload, extra_headers=extra_headers)

            def _err(self, code, ecode, msg, extra_headers=None):
                return Handler._err(self, code, ecode, msg, extra_headers=extra_headers)

            def send_response(self, code, message=None):
                self.status_code = code

            def send_header(self, k, v):
                self.headers_out[k] = v

            def end_headers(self):
                pass

            @property
            def wfile(self):
                mock_self = self
                class Writer:
                    def write(self, b):
                        mock_self.body.extend(b)
                return Writer()

        # 1. HEAD request on 501 (maps to 405 with Allow: GET, HEAD and suppresses body)
        h1 = MockHandler()
        Handler.send_error(h1, 501)
        self.assertEqual(h1.status_code, 405)
        self.assertEqual(h1.headers_out.get("Allow"), "GET, HEAD")
        self.assertEqual(h1.headers_out.get("Content-Type"), "application/json")
        self.assertEqual(len(h1.body), 0)

        # 2. GET request on 501 (maps to 405 with body)
        h2 = MockHandler()
        h2.command = "GET"
        Handler.send_error(h2, 501)
        self.assertEqual(h2.status_code, 405)
        self.assertEqual(h2.headers_out.get("Allow"), "GET, HEAD")
        self.assertGreater(len(h2.body), 0)
        self.assertEqual(h2.headers_out.get("Content-Length"), str(len(h2.body)))

        # 3. HEAD request on 404 suppresses body
        h3 = MockHandler()
        Handler.send_error(h3, 404, "Unknown Resource")
        self.assertEqual(h3.status_code, 404)
        self.assertEqual(len(h3.body), 0)


if __name__ == "__main__":
    unittest.main()
