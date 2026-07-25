#!/usr/bin/env python3
"""Deterministic, in-memory fake for the Signalloom demo integrations.

This process is intentionally not an integration gateway: it makes no outbound
connections and its mutable state disappears when the pod restarts.
"""

from __future__ import annotations

import copy
import json
import os
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import urlparse


ROUTE_PREFIXES = {
    "llm": "/llm/",
    "crm": "/crm/",
    "notification": "/notification/",
    "outbound-reporting": "/outbound-reporting/",
}
SENSITIVE_BODY_KEYS = {
    "authorization", "credential", "credentials", "password", "secret", "token",
    "api_key", "apikey", "access_key", "private_key",
}
CAPTURED_HEADERS = {"content-type", "user-agent", "x-request-id"}

DEFAULT_FIXTURES = {
    "llm": {"default": {"data": [{"id": "demo-assistant-001", "name": "Demo Assistant"}]}},
    "crm": {"default": {"id": "demo-contact-001", "status": "accepted"}},
    "notification": {"default": {"ok": True, "message": "demo notification accepted"}},
    "outbound-reporting": {"default": {"id": "demo-report-001", "status": "queued"}},
}


def redact(value: object, key: str = "") -> object:
    """Return a safe structural representation without retaining secret values."""
    normalised_key = key.lower().replace("-", "_")
    if normalised_key in SENSITIVE_BODY_KEYS or any(marker in normalised_key for marker in SENSITIVE_BODY_KEYS):
        return "[REDACTED]"
    if isinstance(value, dict):
        return {str(k): redact(v, str(k)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


class DemoState:
    def __init__(self) -> None:
        self.lock = Lock()
        self.fixtures = copy.deepcopy(DEFAULT_FIXTURES)
        self.requests: list[dict[str, object]] = []

    def reset_requests(self) -> None:
        with self.lock:
            self.requests.clear()

    def add_request(self, request: dict[str, object]) -> None:
        with self.lock:
            self.requests.append(request)

    def get_requests(self) -> list[dict[str, object]]:
        with self.lock:
            return copy.deepcopy(self.requests)

    def get_fixtures(self) -> dict[str, object]:
        with self.lock:
            return copy.deepcopy(self.fixtures)

    def put_fixture(self, category: str, name: str, fixture: object) -> None:
        with self.lock:
            self.fixtures.setdefault(category, {})[name] = fixture

    def select_fixture(self, category: str, route: str) -> tuple[str, object]:
        name = route.removeprefix(ROUTE_PREFIXES[category]).strip("/").split("/")[-1] or "default"
        with self.lock:
            fixtures = self.fixtures[category]
            selected = name if name in fixtures else "default"
            return selected, copy.deepcopy(fixtures[selected])


class ProxyHandler(BaseHTTPRequestHandler):
    state = DemoState()
    server_version = "SignalloomDemoProxy/1.0"

    @property
    def demo_controls_enabled(self) -> bool:
        return os.environ.get("SIGNALLOOM_DEMO_PROFILE") == "demo"

    def log_message(self, format: str, *args: object) -> None:
        # Request bodies and headers must never reach stdout/stderr logs.
        return

    def _json(self, status: int, payload: object) -> None:
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _body(self) -> object:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return None
        try:
            return redact(json.loads(raw.decode("utf-8")))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return "[REDACTED_NON_JSON_BODY]"

    def _business_route(self, path: str) -> str | None:
        for category, prefix in ROUTE_PREFIXES.items():
            if path.startswith(prefix):
                return category
        return None

    def _capture(self, category: str, path: str, body: object, fixture: str) -> None:
        headers = {key: self.headers[key] for key in CAPTURED_HEADERS if key in self.headers}
        self.state.add_request({
            "method": self.command,
            "category": category,
            "route": path,
            "selected_fixture": fixture,
            "headers": headers,
            "body": body,
        })

    def _handle_business(self) -> bool:
        path = urlparse(self.path).path
        category = self._business_route(path)
        if category is None:
            return False
        body = self._body() if self.command in {"POST", "PUT", "PATCH"} else None
        fixture_name, fixture = self.state.select_fixture(category, path)
        self._capture(category, path, body, fixture_name)
        self._json(HTTPStatus.OK, fixture)
        return True

    def _handle_control(self) -> bool:
        path = urlparse(self.path).path
        if not path.startswith("/_test/"):
            return False
        if not self.demo_controls_enabled:
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return True
        if path == "/_test/requests" and self.command == "GET":
            self._json(HTTPStatus.OK, {"requests": self.state.get_requests()})
            return True
        if path == "/_test/requests" and self.command == "DELETE":
            self.state.reset_requests()
            self._json(HTTPStatus.OK, {"requests": []})
            return True
        if path == "/_test/fixtures" and self.command == "GET":
            self._json(HTTPStatus.OK, {"fixtures": self.state.get_fixtures()})
            return True
        parts = path.split("/")
        if len(parts) == 5 and parts[:3] == ["", "_test", "fixtures"] and self.command == "PUT":
            category, name = parts[3], parts[4]
            if category not in ROUTE_PREFIXES or not name:
                self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return True
            body = self._body()
            if body is None:
                self._json(HTTPStatus.BAD_REQUEST, {"error": "fixture body is required"})
                return True
            self.state.put_fixture(category, name, body)
            self._json(HTTPStatus.OK, {"category": category, "name": name, "fixture": body})
            return True
        self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        return True

    def _dispatch(self) -> None:
        if self.path == "/health" and self.command == "GET":
            self._json(HTTPStatus.OK, {"status": "ok"})
        elif self._handle_control() or self._handle_business():
            return
        else:
            self._json(HTTPStatus.NOT_FOUND, {"error": "unknown route"})

    do_GET = _dispatch
    do_POST = _dispatch
    do_PUT = _dispatch
    do_PATCH = _dispatch
    do_DELETE = _dispatch


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), ProxyHandler).serve_forever()


if __name__ == "__main__":
    main()
