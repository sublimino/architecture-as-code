"""Minimal stdlib HTTP server helper shared by the services, so each one is a
small routes table instead of a full framework. Binds on all interfaces
(config.BIND_HOST) so the co-located services are reachable as a Service."""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import config


def send_json(handler: BaseHTTPRequestHandler, code: int, obj: dict) -> None:
    body = json.dumps(obj).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def read_json(handler: BaseHTTPRequestHandler) -> dict:
    length = int(handler.headers.get("Content-Length", 0) or 0)
    if not length:
        return {}
    try:
        return json.loads(handler.rfile.read(length) or b"{}")
    except json.JSONDecodeError:
        return {}


def query(handler: BaseHTTPRequestHandler) -> dict:
    raw = parse_qs(urlparse(handler.path).query)
    return {k: v[0] for k, v in raw.items()}


def build_server(port: int, routes: dict) -> ThreadingHTTPServer:
    """routes maps (METHOD, path) -> fn(handler). The fn reads body/query/headers
    from the handler and calls send_json itself."""

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # quiet
            pass

        def _dispatch(self, method: str):
            path = urlparse(self.path).path.rstrip("/") or "/"
            fn = routes.get((method, path))
            if fn is None:
                send_json(self, 404, {"error": f"no route {method} {path}"})
                return
            try:
                fn(self)
            except Exception as exc:  # noqa: BLE001 - surface the error
                send_json(self, 500, {"error": str(exc)})

        def do_GET(self):
            self._dispatch("GET")

        def do_POST(self):
            self._dispatch("POST")

    return ThreadingHTTPServer((config.BIND_HOST, port), Handler)


def serve_in_thread(server: ThreadingHTTPServer) -> threading.Thread:
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return t
