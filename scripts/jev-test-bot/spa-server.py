#!/usr/bin/env python3
"""Serve a single-page app directory over loopback, with SPA history fallback.

Why this exists rather than `vite preview`: the loop has to be runnable with
no network and no `node_modules`, and `npm install` is neither. `vite dev` is
used when the dependency tree happens to be installed (`--dashboard-mode
vite`); this is the always-available fallback.

What it gives up, stated plainly: no bundling, no JS execution, no API proxy.
Every unknown path returns `index.html` — which is exactly what a real Vite
server, and the production nginx config, also do for an SPA route. Since
`bot.py` fetches over `urllib` and never runs JavaScript, the two are
indistinguishable from the bot's side: both answer every route with the same
document shell. That is a real limit on what the loop can find, and it is
documented in `docs/signalloom/runbooks/jev-exploration-loop.md` rather than
papered over.

Only loopback is bound. Only GET, HEAD, and OPTIONS are answered.
"""

from __future__ import annotations

import argparse
import os
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler


class SpaHandler(SimpleHTTPRequestHandler):
    """Static files where they exist; the app shell everywhere else."""

    index_name = "index.html"

    def translate_path(self, path: str) -> str:
        resolved = super().translate_path(path)
        # Directory or missing file → hand back the shell, the way a client-side
        # router expects. Guard against escaping the served root: translate_path
        # already normalises away `..`, but assert it rather than assume it.
        root = os.path.realpath(self.directory)
        real = os.path.realpath(resolved)
        if not (real == root or real.startswith(root + os.sep)):
            return os.path.join(root, self.index_name)
        if os.path.isdir(real) or not os.path.exists(real):
            return os.path.join(root, self.index_name)
        return resolved

    def _drain_body(self) -> None:
        if not hasattr(self, "headers") or not self.headers:
            return
        te = self.headers.get("Transfer-Encoding", "").lower()
        if "chunked" in te:
            try:
                total = 0
                while total <= 1048576:
                    line = self.rfile.readline(128)
                    if not line:
                        break
                    chunk_len_str = line.split(b";")[0].strip()
                    if not chunk_len_str:
                        break
                    chunk_len = int(chunk_len_str, 16)
                    if chunk_len == 0:
                        while True:
                            trailer = self.rfile.readline(1024)
                            if not trailer or trailer in (b"\r\n", b"\n", b""):
                                break
                        break
                    total += chunk_len
                    if total > 1048576:
                        self.close_connection = True
                        break
                    rem = chunk_len
                    while rem > 0:
                        b = self.rfile.read(min(rem, 65536))
                        if not b:
                            self.close_connection = True
                            return
                        rem -= len(b)
                    self.rfile.readline(4)
            except Exception:
                self.close_connection = True
            return

        try:
            raw_len = self.headers.get("Content-Length", "0")
            length = int(raw_len.strip()) if raw_len else 0
        except (ValueError, TypeError, AttributeError):
            length = 0
        if 0 < length <= 1048576:
            try:
                rem = length
                while rem > 0:
                    b = self.rfile.read(min(rem, 65536))
                    if not b:
                        self.close_connection = True
                        break
                    rem -= len(b)
            except (OSError, ValueError):
                pass
        elif length > 1048576:
            self.close_connection = True

    def _send_405(self):
        if hasattr(self, "_drain_body"):
            self._drain_body()
        msg = "This stub serves GET, HEAD, and OPTIONS only"
        body = msg.encode("utf-8")
        self.send_response(405)
        self.send_header("Allow", "GET, HEAD, OPTIONS")
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if getattr(self, "close_connection", False):
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_error(self, code, message=None, explain=None):
        if code in (405, 501):
            if hasattr(self, "_drain_body"):
                self._drain_body()
            body = b"This stub serves GET, HEAD, and OPTIONS only"
            self.send_response(405)
            self.send_header("Allow", "GET, HEAD, OPTIONS")
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            if getattr(self, "close_connection", False):
                self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return
        err_msg = message or (self.responses.get(code, ("error",))[0])
        body = f'{{"error": "{err_msg}", "code": {code}}}\n'.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if getattr(self, "close_connection", False):
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_POST(self):  # noqa: N802 — handler naming is the base class's
        self._send_405()

    def do_PUT(self):  # noqa: N802
        self._send_405()

    def do_DELETE(self):  # noqa: N802
        self._send_405()

    def do_PATCH(self):  # noqa: N802
        self._send_405()

    def do_OPTIONS(self):  # noqa: N802
        if hasattr(self, "_drain_body"):
            self._drain_body()
        self.send_response(204)
        self.send_header("Allow", "GET, HEAD, OPTIONS")
        if getattr(self, "close_connection", False):
            self.send_header("Connection", "close")
        self.end_headers()

    def log_message(self, fmt, *args):
        # One line per request on stderr, so the run log shows what was asked
        # for. The default also prints to stderr but with a noisier prefix.
        sys.stderr.write("spa-server %s - %s\n" % (self.address_string(), fmt % args))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Loopback SPA server with history fallback")
    parser.add_argument("--directory", required=True, help="Directory holding index.html")
    parser.add_argument("--port", type=int, required=True, help="Port to bind on 127.0.0.1")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default: loopback)")
    args = parser.parse_args(argv)

    directory = os.path.abspath(args.directory)
    index = os.path.join(directory, SpaHandler.index_name)
    if not os.path.exists(index):
        print(f"spa-server: no {SpaHandler.index_name} in {directory}", file=sys.stderr)
        return 2

    def build(*handler_args, **handler_kwargs):
        return SpaHandler(*handler_args, directory=directory, **handler_kwargs)

    HTTPServer.allow_reuse_address = True
    server = HTTPServer((args.host, args.port), build)
    print(f"spa-server: serving {directory} on http://{args.host}:{args.port}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
