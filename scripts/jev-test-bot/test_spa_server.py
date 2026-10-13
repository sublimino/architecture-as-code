#!/usr/bin/env python3
"""Contract and regression tests for scripts/jev-test-bot/spa-server.py.

Verifies:
1. GET / and static paths return 200 with valid Content-Length and body.
2. HEAD requests to root, static files, and SPA fallback routes return 200 with matching Content-Length and empty body.
3. POST, PUT, DELETE, PATCH, OPTIONS return 405 Method Not Allowed with Allow: GET, HEAD.
4. send_error overrides suppress response body on HEAD for all status codes.
5. Unsupported methods (501) map to 405 with Allow: GET, HEAD.
"""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer

spec = importlib.util.spec_from_file_location(
    "spa_server",
    os.path.join(os.path.dirname(__file__), "spa-server.py"),
)
spa_server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(spa_server)
SpaHandler = spa_server.SpaHandler


class SpaServerContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmpdir = tempfile.TemporaryDirectory()
        cls.root = cls.tmpdir.name
        cls.index_content = b"<!DOCTYPE html><html><body><h1>App Shell</h1></body></html>\n"
        cls.css_content = b"body { margin: 0; background: #000; }\n"

        with open(os.path.join(cls.root, "index.html"), "wb") as f:
            f.write(cls.index_content)
        with open(os.path.join(cls.root, "style.css"), "wb") as f:
            f.write(cls.css_content)

        def handler_factory(*args, **kwargs):
            return SpaHandler(*args, directory=cls.root, **kwargs)

        HTTPServer.allow_reuse_address = True
        cls.server = HTTPServer(("127.0.0.1", 0), handler_factory)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever)
        cls.thread.daemon = True
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2.0)
        cls.tmpdir.cleanup()

    def test_get_root_and_static_files(self):
        url = f"http://127.0.0.1:{self.port}/"
        with urllib.request.urlopen(url) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(resp.headers.get("Content-Length"), str(len(self.index_content)))
            self.assertEqual(resp.read(), self.index_content)

        url_css = f"http://127.0.0.1:{self.port}/style.css"
        with urllib.request.urlopen(url_css) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(resp.headers.get("Content-Length"), str(len(self.css_content)))
            self.assertEqual(resp.read(), self.css_content)

    def test_head_root_and_static_files_suppresses_body(self):
        for path, length in [("/", len(self.index_content)), ("/style.css", len(self.css_content))]:
            req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method="HEAD")
            with urllib.request.urlopen(req) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers.get("Content-Length"), str(length))
                self.assertEqual(resp.read(), b"")

    def test_spa_history_fallback_on_unknown_routes(self):
        for unknown in ["/dashboard", "/governance/nodes", "/deep/nested/view"]:
            # GET fallback
            with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{unknown}") as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers.get("Content-Length"), str(len(self.index_content)))
                self.assertEqual(resp.read(), self.index_content)

            # HEAD fallback
            req = urllib.request.Request(f"http://127.0.0.1:{self.port}{unknown}", method="HEAD")
            with urllib.request.urlopen(req) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers.get("Content-Length"), str(len(self.index_content)))
                self.assertEqual(resp.read(), b"")

    def test_unsupported_methods_return_405_with_allow_header(self):
        for method in ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"]:
            req = urllib.request.Request(f"http://127.0.0.1:{self.port}/", data=b"{}", method=method)
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(req)
            self.assertEqual(ctx.exception.code, 405)
            self.assertEqual(ctx.exception.headers.get("Allow"), "GET, HEAD")
            self.assertEqual(ctx.exception.headers.get("Content-Type"), "text/plain; charset=utf-8")
            body = ctx.exception.read()
            self.assertGreater(len(body), 0)
            self.assertEqual(ctx.exception.headers.get("Content-Length"), str(len(body)))
            ctx.exception.close()

    def test_send_error_head_suppression_and_501_mapping(self):
        # Test unit invocation of send_error directly on mock/simulated handler
        class FakeHandler:
            command = "HEAD"
            responses = {400: ("Bad Request", "Explain"), 405: ("Method Not Allowed", ""), 501: ("Not Implemented", "")}

            def __init__(self):
                self.headers_out = {}
                self.status_code = None
                self.body = bytearray()

            def send_response(self, code, message=None):
                self.status_code = code

            def send_header(self, k, v):
                self.headers_out[k] = v

            def end_headers(self):
                pass

            @property
            def wfile(self):
                handler_self = self
                class Writer:
                    def write(self, b):
                        handler_self.body.extend(b)
                return Writer()

        # 1. HEAD request receiving 405 Method Not Allowed
        h1 = FakeHandler()
        SpaHandler.send_error(h1, 405)
        self.assertEqual(h1.status_code, 405)
        self.assertEqual(h1.headers_out.get("Allow"), "GET, HEAD")
        self.assertEqual(len(h1.body), 0)
        self.assertIsNotNone(h1.headers_out.get("Content-Length"))

        # 2. HEAD request receiving 501 (mapped to 405)
        h2 = FakeHandler()
        SpaHandler.send_error(h2, 501)
        self.assertEqual(h2.status_code, 405)
        self.assertEqual(h2.headers_out.get("Allow"), "GET, HEAD")
        self.assertEqual(len(h2.body), 0)

        # 3. GET request receiving 501 (mapped to 405) has body
        h3 = FakeHandler()
        h3.command = "GET"
        SpaHandler.send_error(h3, 501)
        self.assertEqual(h3.status_code, 405)
        self.assertEqual(h3.headers_out.get("Allow"), "GET, HEAD")
        self.assertGreater(len(h3.body), 0)
        self.assertEqual(h3.headers_out.get("Content-Length"), str(len(h3.body)))

        # 4. HEAD request receiving 400 Bad Request
        h4 = FakeHandler()
        SpaHandler.send_error(h4, 400, "Bad Request")
        self.assertEqual(h4.status_code, 400)
        self.assertEqual(len(h4.body), 0)
        self.assertEqual(h4.headers_out.get("Content-Type"), "application/json; charset=utf-8")

        # 5. GET request receiving 400 Bad Request has JSON body
        h5 = FakeHandler()
        h5.command = "GET"
        SpaHandler.send_error(h5, 400, "Malformed syntax")
        self.assertEqual(h5.status_code, 400)
        self.assertGreater(len(h5.body), 0)
        payload = json.loads(h5.body.decode("utf-8"))
        self.assertEqual(payload["error"], "Malformed syntax")
        self.assertEqual(payload["code"], 400)


if __name__ == "__main__":
    unittest.main()
