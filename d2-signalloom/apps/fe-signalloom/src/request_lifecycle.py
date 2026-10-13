"""HTTP request lifecycle and method parity middleware for fe-signalloom.

Enforces:
1. RFC 9110 Section 9.3.7 OPTIONS discovery: responds to OPTIONS requests on any
   known endpoint with 204 No Content, a canonical Allow header, content-length 0,
   and 0 response body bytes, while draining request body frames.
2. RFC 9110 Section 9.3.2 GET and HEAD parity: transparently routes HEAD requests
   to matching GET endpoints and suppresses response body bytes (Section 6.4.1).
3. RFC 9110 Section 6.4.1 body suppression for 204 No Content and 304 Not Modified.
4. RFC 9110 Section 15.5.6 405 Method Not Allowed canonical Allow header synthesis
   including OPTIONS and all registered methods.
"""
from __future__ import annotations

from typing import Any


def _collect_routes(routes: list[Any]) -> list[Any]:
    all_routes: list[Any] = []
    for r in routes:
        if hasattr(r, "original_router"):
            all_routes.extend(_collect_routes(r.original_router.routes))
        elif hasattr(r, "routes"):
            all_routes.extend(_collect_routes(r.routes))
        else:
            all_routes.append(r)
    return all_routes


def get_allowed_methods(fastapi_app: Any, path: str) -> list[str] | None:
    """Compute allowed HTTP methods for a path across all registered FastAPI routes."""
    if not fastapi_app or not hasattr(fastapi_app, "routes"):
        return None
    methods: set[str] = set()
    found = False
    for r in _collect_routes(fastapi_app.routes):
        regex = getattr(r, "path_regex", None)
        if regex and regex.match(path):
            found = True
            r_methods = getattr(r, "methods", None)
            if r_methods:
                methods.update(r_methods)
    if not found:
        return None
    methods.add("OPTIONS")
    if "GET" in methods:
        methods.add("HEAD")
    order = ["GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]
    return [m for m in order if m in methods]


class RequestLifecycleMiddleware:
    """ASGI middleware ensuring RFC 9110 OPTIONS parity, HEAD body suppression, and 405 Allow headers."""

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        method = scope.get("method")
        path = scope.get("path", "")
        root_app = scope.get("app")

        if method == "OPTIONS":
            allowed = get_allowed_methods(root_app, path)
            if allowed is not None:
                more_body = True
                while more_body:
                    msg = await receive()
                    if msg["type"] == "http.disconnect":
                        return
                    more_body = msg.get("more_body", False)

                allow_str = ", ".join(allowed)
                await send({
                    "type": "http.response.start",
                    "status": 204,
                    "headers": [
                        (b"allow", allow_str.encode("latin-1")),
                        (b"content-length", b"0"),
                    ],
                })
                await send({
                    "type": "http.response.body",
                    "body": b"",
                    "more_body": False,
                })
                return

        response_status = 200

        async def wrapped_send(message: dict[str, Any]) -> None:
            nonlocal response_status
            if message["type"] == "http.response.start":
                response_status = message.get("status", 200)
                if response_status == 405:
                    allowed = get_allowed_methods(root_app, path)
                    if allowed is not None:
                        allow_bytes = ", ".join(allowed).encode("latin-1")
                        headers = [
                            (k, v) for k, v in message.get("headers", [])
                            if k.lower() != b"allow"
                        ]
                        headers.append((b"allow", allow_bytes))
                        message = dict(message)
                        message["headers"] = headers
                await send(message)
            elif message["type"] == "http.response.body":
                if method == "HEAD" or response_status in (204, 304):
                    message = dict(message)
                    message["body"] = b""
                await send(message)

        if method == "HEAD":
            head_scope = dict(scope)
            head_scope["method"] = "GET"
            await self.app(head_scope, receive, wrapped_send)
            return

        await self.app(scope, receive, wrapped_send)


HeadBodySuppressingMiddleware = RequestLifecycleMiddleware
