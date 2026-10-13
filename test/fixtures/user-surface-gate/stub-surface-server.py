#!/usr/bin/env python3
"""A scriptable stand-in for the deployed demo API, used to test the GATE.

This stub exists to exercise scripts/ci/user-surface-gate.sh, NOT to test the
product. The distinction matters here more than usual: the whole reason that
gate was written is that the estate's suites pass against stubs and localhost
while the real URL is broken. So the rule for this file is narrow and worth
stating plainly —

    the stub proves the GATE can tell the verdicts apart.
    only a run against the real tailnet origin proves the PRODUCT works.

Nothing in this directory may ever be cited as evidence that a demo works. The
gate's live invocation in the pipeline is that evidence, and it takes a real
base URL with no localhost default precisely so this file cannot stand in for
it by accident.

Behaviour is driven by a JSON scenario file given as argv[2], mapping a demo
type to how its surface should behave:

    {"supercred": {"status": "healthy"},
     "signalfusion": {"status": "incapable"}}

Modes: healthy · incapable (200 + script_available false) · missing (404) ·
forbidden (403) · error503 · nosteps · runfails · failsecond · runhangs
"""

from __future__ import annotations

import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCENARIO: dict = {}
RUNS: dict = {}
LOCK = threading.Lock()
TOKEN = "stub-id-token-for-gate-tests"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):  # keep bats output readable
        pass

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError):
            self.close_connection = True

    def _send(self, code: int, payload: dict, extra_headers: dict | None = None):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        if getattr(self, "close_connection", False):
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _err(self, code: int, ecode: str, msg: str, extra_headers: dict | None = None):
        self._send(code, {"error": {"code": ecode, "message": msg}}, extra_headers=extra_headers)

    def _send_405(self, allow: str):
        self._err(405, "method_not_allowed", f"Method {self.command} not allowed", extra_headers={"Allow": allow})

    def send_error(self, code: int, message: str | None = None, explain: str | None = None):
        extra_headers = {}
        if code in (405, 501):
            path = getattr(self, "path", "/")
            allowed = self._allowed_methods_for_path(path) if hasattr(self, "_allowed_methods_for_path") else None
            extra_headers["Allow"] = allowed or "GET, HEAD, POST"
            if code == 501:
                code = 405
        msg = message or self.responses.get(code, ("Error", ""))[0]
        self._err(code, "http_error", msg, extra_headers=extra_headers)

    def _authed(self) -> bool:
        auth = self.headers.get("Authorization", "")
        return auth.strip() == f"Bearer {TOKEN}"

    def _allowed_methods_for_path(self, path: str) -> str | None:
        clean_path = path.split("?")[0].rstrip("/") or "/"
        if clean_path in ("/health", "/healthz", "/readyz"):
            return "GET, HEAD"
        if clean_path == "/dex/token":
            return "POST"
        if re.match(r"^/api/demo/([^/]+)/runs$", clean_path):
            return "POST"
        if re.match(r"^/api/demo/([^/]+)/(status|steps)$", clean_path):
            return "GET, HEAD"
        if re.match(r"^/api/demo/([^/]+)/runs/([^/]+)$", clean_path):
            return "GET, HEAD"
        return None

    def _handle_unsupported_method(self):
        allowed = self._allowed_methods_for_path(self.path)
        if allowed:
            self._send_405(allowed)
        else:
            self._err(404, "not_found", "no such route")

    def do_HEAD(self):
        self.do_GET()

    def do_PUT(self):
        self._handle_unsupported_method()

    def do_DELETE(self):
        self._handle_unsupported_method()

    def do_PATCH(self):
        self._handle_unsupported_method()

    def do_OPTIONS(self):
        self._handle_unsupported_method()

    # Dex password grant. The gate refuses to run without a token, so a stub
    # that cannot mint one would exercise only the CANNOT-RUN path.
    def do_POST(self):
        clean_path = self.path.split("?")[0].rstrip("/") or "/"
        if clean_path in ("/health", "/healthz", "/readyz") or re.match(r"^/api/demo/([^/]+)/(status|steps)$", clean_path) or re.match(r"^/api/demo/([^/]+)/runs/([^/]+)$", clean_path):
            self._send_405("GET, HEAD")
            return

        te = self.headers.get("Transfer-Encoding", "").lower()
        if "chunked" in te:
            chunks = []
            total = 0
            while total <= 1048576:
                line = self.rfile.readline(128)
                if not line:
                    self.close_connection = True
                    break
                chunk_len_str = line.split(b";")[0].strip()
                if not chunk_len_str or not re.fullmatch(rb"[0-9a-fA-F]+", chunk_len_str):
                    self.close_connection = True
                    self._err(400, "invalid_chunk", "invalid chunk length")
                    return
                chunk_len = int(chunk_len_str, 16)
                if chunk_len < 0:
                    self.close_connection = True
                    self._err(400, "invalid_chunk", "negative chunk length")
                    return
                if chunk_len == 0:
                    while True:
                        trailer = self.rfile.readline(1024)
                        if not trailer:
                            self.close_connection = True
                            break
                        if trailer in (b"\r\n", b"\n"):
                            break
                    break
                total += chunk_len
                if total > 1048576:
                    self.close_connection = True
                    self._err(413, "payload_too_large", "payload exceeds limit")
                    return
                rem = chunk_len
                chunk_bytes = bytearray()
                while rem > 0:
                    b = self.rfile.read(min(rem, 65536))
                    if not b:
                        self.close_connection = True
                        self._err(400, "premature_eof", "premature EOF reading chunk data")
                        return
                    chunk_bytes.extend(b)
                    rem -= len(b)
                chunks.append(bytes(chunk_bytes))
                delim = self.rfile.readline(4)
                if delim not in (b"\r\n", b"\n"):
                    self.close_connection = True
                    self._err(400, "invalid_chunk", "malformed chunk delimiter")
                    return
            raw = b"".join(chunks).decode("utf-8", errors="replace")
        else:
            raw_len = self.headers.get("Content-Length")
            if raw_len is not None:
                try:
                    length = int(raw_len.strip())
                except ValueError:
                    self.close_connection = True
                    self._err(400, "invalid_length", "invalid Content-Length header")
                    return
                if length < 0:
                    self.close_connection = True
                    self._err(400, "invalid_length", "negative Content-Length header")
                    return
            else:
                length = 0
            if length > 1048576:
                self.close_connection = True
                self._err(413, "payload_too_large", "payload exceeds limit")
                return
            if length > 0:
                raw_bytes = self.rfile.read(length)
                if len(raw_bytes) < length:
                    self.close_connection = True
                    self._err(400, "premature_eof", "premature EOF reading body")
                    return
                raw = raw_bytes.decode("utf-8", errors="replace")
            else:
                raw = ""
        if self.path.rstrip("/") == "/dex/token":
            if SCENARIO.get("_dex") == "down":
                self._err(500, "dex_down", "stub Dex refuses to mint")
                return
            self._send(200, {"id_token": TOKEN, "access_token": TOKEN})
            return

        m = re.match(r"^/api/demo/([^/]+)/runs$", self.path)
        if not m:
            self._err(404, "not_found", "no such route")
            return
        demo, mode = m.group(1), self._mode(m.group(1))
        if mode == "missing":
            self._err(404, "not_found", "no such route")
            return
        if not self._authed():
            self._err(401, "authentication_required", "Bearer authentication is required")
            return
        if mode in ("incapable", "error503"):
            self._err(503, "demo_root_unresolved", f"must set {demo.upper()}_DEMO_CWD")
            return
        try:
            step = json.loads(raw).get("step")
        except Exception:
            step = None
        run_id = f"run-{demo}-{step}"
        with LOCK:
            RUNS[run_id] = {
                "run_id": run_id,
                "status": "running",
                "started": time.time(),
                "mode": mode,
            }
        self._send(202, {"run_id": run_id, "status": "running", "step": step})

    def do_GET(self):
        clean_path = self.path.split("?")[0].rstrip("/") or "/"
        if clean_path == "/dex/token" or re.match(r"^/api/demo/([^/]+)/runs$", clean_path):
            self._send_405("POST")
            return

        if clean_path in ("/health", "/healthz", "/readyz"):
            self._send(200, {"status": "ok"})
            return

        m = re.match(r"^/api/demo/([^/]+)/(status|steps)$", self.path)
        if m:
            demo, what, mode = m.group(1), m.group(2), self._mode(m.group(1))
            if mode == "missing":
                self._err(404, "not_found", "no such route")
                return
            if not self._authed():
                self._err(401, "authentication_required", "Bearer authentication is required")
                return
            if mode == "forbidden":
                self._err(403, "forbidden", "superadmin required")
                return
            if mode == "error503":
                self._err(503, "demo_root_unresolved", f"must set {demo.upper()}_DEMO_CWD")
                return
            if what == "status":
                self._send(200, {
                    "active": None, "recent": [],
                    "script_available": mode != "incapable",
                })
                return
            steps = [] if mode == "nosteps" else [
                {"step_id": "1", "title": "One", "description": "first act"},
                {"step_id": "2", "title": "Two", "description": "second act"},
            ]
            self._send(200, {"steps": steps})
            return

        m = re.match(r"^/api/demo/([^/]+)/runs/([^/]+)$", self.path)
        if m:
            if not self._authed():
                self._err(401, "authentication_required", "Bearer authentication is required")
                return
            with LOCK:
                run = RUNS.get(m.group(2))
            if run is None:
                self._err(404, "run_not_found", "no such run")
                return
            # Terminal only after a beat, so the gate's polling loop is real.
            elapsed = time.time() - run["started"]
            if run["mode"] == "runhangs":
                status = "running"
            elif elapsed < 1.0:
                status = "running"
            elif run["mode"] == "runfails":
                status = "failed"
            elif run["mode"] == "failsecond":
                # Act 1 passes, act 2 fails -- SuperCred's exact shape, and the
                # one a single-step gate sails straight past.
                status = "failed" if run["run_id"].endswith("-2") else "succeeded"
            else:
                status = "succeeded"
            out = {"run_id": run["run_id"], "status": status}
            if status == "failed":
                out.update({"exit_code": 3, "error": "stub demo step failed"})
            self._send(200, out)
            return

        self._err(404, "not_found", "no such route")

    def _mode(self, demo: str) -> str:
        entry = SCENARIO.get(demo)
        if entry is None:
            return "missing"
        return entry.get("status", "healthy") if isinstance(entry, dict) else str(entry)


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        exc_type, _, _ = sys.exc_info()
        if exc_type in (ConnectionResetError, BrokenPipeError):
            return
        super().handle_error(request, client_address)


def main(argv: list[str]) -> int:
    global SCENARIO
    if len(argv) != 3:
        print(f"usage: {argv[0]} <port> <scenario.json>", file=sys.stderr)
        return 2
    SCENARIO = json.loads(open(argv[2]).read())
    server = ReusableThreadingHTTPServer(("127.0.0.1", int(argv[1])), Handler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
