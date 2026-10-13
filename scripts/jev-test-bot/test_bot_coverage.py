"""Unit tests for the bot's route-coverage instrumentation.

Run: python3 -m pytest scripts/jev-test-bot/test_bot_coverage.py -q

`visited_urls` was a set of mixed full URLs and bare paths, which is fine for
the bot's own "have I been here" check and useless for answering "which routes
did this run actually touch?" — the question the loop reports on. So the bot
now also keeps `visited_paths`: normalised, deduped, in visit order, with the
HTTP status each path returned.

These tests pin the normalisation, because that is where a coverage report
quietly lies: if `/agents/` and `/agents` count as two routes, or `/agents?x=1`
counts as a third, then a run looks broader than it was and a route the loop
asked for looks unvisited even though it was fetched.
"""

import http.server
import os
import socket
import sys
import threading
import urllib.error
import urllib.request

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bot  # noqa: E402


class _Shell(http.server.BaseHTTPRequestHandler):
    """A one-page SPA shell: every path answers 200 with the same document.

    This is what the dashboard itself does over plain HTTP, so it is a fair
    stand-in for asserting that the run loop records what it fetched.
    """

    BODY = (
        b"<!doctype html><html><head><title>Stub</title></head>"
        b'<body><a href="/risk">Risk</a></body></html>'
    )

    def _serve(self, send_body=True):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(self.BODY)))
        self.end_headers()
        if send_body:
            self.wfile.write(self.BODY)

    def do_GET(self):  # noqa: N802 — BaseHTTPRequestHandler's required name
        self._serve(send_body=True)

    def do_HEAD(self):  # noqa: N802
        self._serve(send_body=False)

    def send_error(self, code, message=None, explain=None):
        if code == 501:
            err_body = b"Method Not Allowed\n"
            self.send_response(405)
            self.send_header("Allow", "GET, HEAD")
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(err_body)))
            self.end_headers()
            self.wfile.write(err_body)
            return
        super().send_error(code, message=message, explain=explain)

    def log_message(self, *_args):  # keep the test output clean
        return


class ReusableHTTPServer(http.server.HTTPServer):
    allow_reuse_address = True


@pytest.fixture
def stub_server():
    """A loopback HTTP server on a kernel-assigned port, torn down after."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    server = ReusableHTTPServer(("127.0.0.1", port), _Shell)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)



def test_normalise_strips_query_and_fragment():
    assert bot.normalise_path("/agents?tenant=demo") == "/agents"
    assert bot.normalise_path("/agents#panel") == "/agents"
    assert bot.normalise_path("/agents?a=1#b") == "/agents"


def test_normalise_strips_trailing_slash_but_keeps_root():
    assert bot.normalise_path("/agents/") == "/agents"
    assert bot.normalise_path("/") == "/"
    assert bot.normalise_path("") == "/"
    assert bot.normalise_path("?x=1") == "/"


def test_normalise_accepts_absolute_urls_and_keeps_only_the_path():
    assert bot.normalise_path("http://127.0.0.1:41234/agents") == "/agents"
    assert bot.normalise_path("https://host.example/compliance/risk?x=1") == "/compliance/risk"
    assert bot.normalise_path("http://127.0.0.1:41234") == "/"


def test_normalise_adds_a_leading_slash_to_a_bare_path():
    assert bot.normalise_path("agents") == "/agents"


def test_record_visit_dedupes_in_order_and_keeps_status():
    instance = bot.JevExploratoryTestBot(base_url="http://127.0.0.1:1", mock=True)
    instance.record_visit("/agents", 200)
    instance.record_visit("/agents/", 200)
    instance.record_visit("/risk?x=1", 500)
    assert instance.visited_paths == ["/agents", "/risk"]
    assert instance.path_status == {"/agents": 200, "/risk": 500}


def test_record_visit_keeps_the_worst_status_seen_for_a_path():
    """A path that 500s once and 200s later is not a healthy path."""
    instance = bot.JevExploratoryTestBot(base_url="http://127.0.0.1:1", mock=True)
    instance.record_visit("/risk", 500)
    instance.record_visit("/risk", 200)
    assert instance.path_status["/risk"] == 500


def test_summary_reports_visited_paths():
    """The run summary must carry the coverage keys the loop report reads."""
    instance = bot.JevExploratoryTestBot(
        base_url="http://127.0.0.1:1", max_turns=1, timeout=1, mock=True
    )
    summary = instance.run()
    for key in ("visited_paths", "path_status", "visited_urls"):
        assert key in summary, f"summary lost the {key} key"
    assert isinstance(summary["visited_paths"], list)
    assert isinstance(summary["path_status"], dict)


def test_the_run_loop_records_the_route_it_was_pointed_at(stub_server):
    """The call site, not just the recorder.

    Without this the loop could stop calling `record_visit` entirely and every
    other test here would still pass while the run reported zero coverage —
    which is the exact failure this instrumentation exists to prevent.
    """
    instance = bot.JevExploratoryTestBot(
        base_url=stub_server, area="/compliance/risk", max_turns=2, timeout=10, mock=True
    )
    summary = instance.run()
    assert summary["visited_paths"], "a successful fetch recorded no visited route"
    assert "/compliance/risk" == summary["visited_paths"][0], summary["visited_paths"]
    assert summary["path_status"]["/compliance/risk"] == 200


def test_shell_stub_head_and_unsupported_methods(stub_server):
    """HEAD must return 200 with Content-Length and no body; POST must return 405 with Allow header."""
    head_req = urllib.request.Request(f"{stub_server}/risk", method="HEAD")
    with urllib.request.urlopen(head_req) as resp:
        assert resp.status == 200
        assert resp.headers.get("Content-Length") == str(len(_Shell.BODY))
        assert resp.read() == b""

    post_req = urllib.request.Request(f"{stub_server}/risk", data=b"data", method="POST")
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(post_req)
    err = exc_info.value
    try:
        assert err.code == 405
        allow = err.headers.get("Allow", "")
        assert "GET" in allow and "HEAD" in allow
    finally:
        err.close()

