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

    def _send(self, code: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _err(self, code: int, ecode: str, msg: str):
        self._send(code, {"error": {"code": ecode, "message": msg}})

    def _authed(self) -> bool:
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    # Dex password grant. The gate refuses to run without a token, so a stub
    # that cannot mint one would exercise only the CANNOT-RUN path.
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
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


def main(argv: list[str]) -> int:
    global SCENARIO
    if len(argv) != 3:
        print(f"usage: {argv[0]} <port> <scenario.json>", file=sys.stderr)
        return 2
    SCENARIO = json.loads(open(argv[2]).read())
    server = ThreadingHTTPServer(("127.0.0.1", int(argv[1])), Handler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
