"""The SSE push route must be a second reader, never a second source of truth.

`GET /runs/{id}/stream` is additive: `/log` stays the tested default and a
client that ignores SSE entirely keeps working unchanged. That framing decides
what is worth testing here. The interesting failures are not "does it emit
JSON" but:

  * Do frames actually arrive DURING the run? This is the same class of defect
    as the read(8192) batching bug in _monitor_run -- a stream that assembles
    everything and sends it at the end satisfies every content assertion.
  * Does it agree with /log byte for byte? Two readers over one buffer can be
    proven identical; two capture paths off the subprocess could not, and the
    one nobody watches is the one that drifts.
  * Does a client that walks away leave anything behind? A per-connection
    generator still polling after the browser closed the tab is a leak that
    only shows up as a slowly dying pod, hours later, mid-demo.
  * Does it reach the same audience as /log? The route carries the demo
    script's raw stdout -- kubectl output, OpenBao policy paths, failure text.
    Changing the transport must not change the gate.
  * Does an already-finished run terminate, or hang waiting for output that can
    never come?

WHY A REAL SERVER, and not the suite's usual TestClient:

  starlette's TestClient cannot exercise streaming at all. Its transport runs
  the whole ASGI app to completion inside a portal, writing every body chunk
  into an io.BytesIO, and only then hands back an httpx.Response wrapping the
  finished bytes (starlette 0.41.3, _TestClientTransport.handle_request). So
  `client.stream(...)` there yields a response that was already complete before
  the first line was read: arrival times are meaningless, and a disconnect has
  nothing left to disconnect from. Writing this file against TestClient would
  have reproduced, in the tests, the exact mistake the tests exist to catch --
  green assertions that cannot distinguish streaming from batching.

  So these run uvicorn on an ephemeral port in a thread and drive it with a
  real httpx client over a real socket. Everything else in the suite that does
  not care about time still uses TestClient, and should.
"""
from __future__ import annotations

import asyncio
import json
import threading
import time
from contextlib import ExitStack
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Callable, Iterator, cast

import httpx
import pytest
import uvicorn

import api_compat
import demo_runner
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

# Same reasoning as tests/test_demo_runner_streaming.py: the JWT machinery is
# already proven in the suite's main demo-runner file and a second copy is a
# second thing to keep in step with the issuer settings.
from test_demo_runner import (
    NON_SUPERADMIN_SUBJECT,
    SUBJECT_TENANTS,
    SUPERADMIN_EMAIL,
    SUPERADMIN_SUBJECT,
    _bearer,
    _ReadyPool,
    _TestJWKClient,
)

_STREAM_PATH = "/api/demo/supercred/runs/{run_id}/stream"
_LOG_PATH = "/api/demo/supercred/runs/{run_id}/log"

# ~2.5s of output in 10 instalments, so a test can watch frames arrive spread
# across the run rather than in one batch at the end.
_TICKING_SCRIPT = (
    "#!/usr/bin/env bash\n"
    "for i in $(seq 1 10); do\n"
    "  printf 'tick %02d\\n' \"$i\"\n"
    "  sleep 0.25\n"
    "done\n"
)

# ~7s, for the tests that must still be watching a live run after several
# connect/disconnect cycles.
_LONG_SCRIPT = (
    "#!/usr/bin/env bash\n"
    "for i in $(seq 1 28); do\n"
    "  printf 'tick %02d\\n' \"$i\"\n"
    "  sleep 0.25\n"
    "done\n"
)

# Prints nothing for a while. The only frames a correct implementation can send
# during that silence are keepalive comments.
_SILENT_SCRIPT = "#!/usr/bin/env bash\nsleep 1.5\necho 'finally something'\n"

# Multi-byte characters, in a burst, so chunk boundaries have something to
# straddle. The demo script really does print these -- check marks and box
# drawing around its phase banners.
_UNICODE_LINE = "✅ crédential-chaîne 🔐 ✓ ──────────"
_UNICODE_SCRIPT = (
    "#!/usr/bin/env bash\n"
    "for i in $(seq 1 500); do\n"
    f"  printf '%s %03d\\n' '{_UNICODE_LINE}' \"$i\"\n"
    "done\n"
)
_EXPECTED_UNICODE = "".join(f"{_UNICODE_LINE} {index:03d}\n" for index in range(1, 501))


@dataclass(frozen=True)
class _Frame:
    """One SSE frame and when it reached the client.

    ``at`` is why this is a dataclass and not a tuple: arrival time is a
    first-class property of a push stream, and a parser that discarded it could
    not tell a live stream from a batched one.
    """

    event: str
    data: Any
    at: float


@pytest.fixture(autouse=True)
def reset_demo_runner_state() -> Iterator[None]:
    demo_runner.reset_state_for_testing()
    yield
    demo_runner.reset_state_for_testing()


@pytest.fixture
def demo_server(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> Iterator[Callable[[str], httpx.Client]]:
    """A real uvicorn server on an ephemeral port, driven over a real socket."""
    stack = ExitStack()
    running: list[tuple[uvicorn.Server, threading.Thread]] = []

    def _make(script_body: str) -> httpx.Client:
        script_path = tmp_path / "sse-demo.sh"
        script_path.write_text(script_body, encoding="utf-8")
        script_path.chmod(0o755)

        # The server runs in a thread of THIS process, so the module-level
        # patches below are the same objects the app resolves at request time.
        monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
        monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
        monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
        monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
        monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
        monkeypatch.setattr(settings, "api_superadmin_subjects", {SUPERADMIN_SUBJECT})
        monkeypatch.setattr(settings, "api_superadmin_emails", {SUPERADMIN_EMAIL})
        monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())
        monkeypatch.setenv("SUPERCRED_DEMO_SCRIPT", str(script_path))
        monkeypatch.setenv("SUPERCRED_DEMO_CWD", str(tmp_path))
        set_pool_for_testing(_ReadyPool())

        # port=0 lets the kernel pick, so parallel or repeated runs cannot
        # collide on a hardcoded port.
        server = uvicorn.Server(
            uvicorn.Config(app, host="127.0.0.1", port=0, log_level="error", access_log=False)
        )
        # uvicorn skips signal-handler installation off the main thread, which
        # is what makes this recipe work at all.
        thread = threading.Thread(target=server.run, daemon=True, name="sse-test-server")
        thread.start()
        deadline = time.monotonic() + 30
        while not server.started and time.monotonic() < deadline:
            time.sleep(0.01)
        assert server.started, "the test server never finished starting"
        running.append((server, thread))

        port = server.servers[0].sockets[0].getsockname()[1]
        return stack.enter_context(
            httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=30.0)
        )

    try:
        yield _make
    finally:
        stack.close()
        for server, thread in running:
            server.should_exit = True
            thread.join(timeout=15)
            assert not thread.is_alive(), "the test server did not shut down"
        set_pool_for_testing(None)


def _start_run(client: httpx.Client) -> str:
    response = client.post(
        "/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer(SUPERADMIN_SUBJECT)
    )
    assert response.status_code == 202
    return cast(str, response.json()["run_id"])


def _run_status(client: httpx.Client, run_id: str) -> str:
    payload = client.get(
        f"/api/demo/supercred/runs/{run_id}", headers=_bearer(SUPERADMIN_SUBJECT)
    ).json()
    return cast(str, payload["status"])


def _wait_for_terminal_run(client: httpx.Client, run_id: str) -> str:
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        status = _run_status(client, run_id)
        if status != "running":
            return status
        time.sleep(0.05)
    raise AssertionError(f"run {run_id} did not finish before deadline")


def _whole_log(client: httpx.Client, run_id: str) -> str:
    """Everything /log has, walked through the paging protocol."""
    text = ""
    offset = 0
    while True:
        payload = client.get(
            _LOG_PATH.format(run_id=run_id),
            headers=_bearer(SUPERADMIN_SUBJECT),
            params={"offset": offset},
        ).json()
        text += payload["chunk"]
        if payload["next_offset"] == offset:
            return text
        offset = payload["next_offset"]


def _read_frames(
    response: httpx.Response,
    *,
    stop_after: str | None = "end",
    max_frames: int | None = None,
    deadline_seconds: float = 40.0,
) -> list[_Frame]:
    """Parse SSE frames off a live response, recording arrival times.

    Keepalive comments are surfaced as _Frame("comment", raw_line) rather than
    being silently swallowed by a tolerant parser, so a test can assert the
    silence really was filled.
    """
    frames: list[_Frame] = []
    fields: dict[str, str] = {}
    deadline = time.monotonic() + deadline_seconds
    for raw_line in response.iter_lines():
        now = time.monotonic()
        if now > deadline:
            raise AssertionError(f"stream did not reach {stop_after!r} within {deadline_seconds}s")
        line = raw_line.rstrip("\r")
        if line.startswith(":"):
            frames.append(_Frame("comment", line, now))
        elif line == "":
            if fields:
                frames.append(_Frame(fields.get("event", "message"), json.loads(fields["data"]), now))
                fields = {}
        else:
            field, _, value = line.partition(":")
            fields[field] = value[1:] if value.startswith(" ") else value
        if max_frames is not None and len(frames) >= max_frames:
            return frames
        if stop_after is not None and frames and frames[-1].event == stop_after:
            return frames
    return frames


def _parse_frame(raw: bytes) -> _Frame:
    """One frame's raw bytes, as yielded by the generator, into a _Frame."""
    fields: dict[str, str] = {}
    for line in raw.decode("utf-8").split("\n"):
        if line.startswith(":"):
            return _Frame("comment", line, time.monotonic())
        if line:
            field, _, value = line.partition(":")
            fields[field] = value[1:] if value.startswith(" ") else value
    return _Frame(fields.get("event", "message"), json.loads(fields["data"]), time.monotonic())


def _synthetic_run() -> demo_runner._Run:
    """A run with no subprocess, whose log a test fills by hand.

    Lets the generator be driven against an exactly-controlled buffer. Nothing
    here spawns, so it cannot depend on how fast a shell happens to be.
    """
    run_lock = threading.Lock()
    return demo_runner._Run(
        run_id="synthetic-run",
        step_id="1",
        kind="step",
        status="running",
        started_at=datetime.now(UTC),
        finished_at=None,
        exit_code=None,
        error=None,
        _process=None,
        _log=bytearray(),
        _log_truncated=False,
        _timed_out=False,
        _lock=run_lock,
        _log_changed=threading.Condition(run_lock),
        _done=threading.Event(),
    )


def _logs(frames: list[_Frame]) -> list[dict[str, Any]]:
    return [frame.data for frame in frames if frame.event == "log"]


def _streamed_text(frames: list[_Frame]) -> str:
    return "".join(payload["chunk"] for payload in _logs(frames))


def test_frames_arrive_spread_across_the_run_rather_than_in_one_batch(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    """The load-bearing test, and the reason this file needs a real socket.

    Every other assertion here is satisfied by an implementation that collects
    the whole log and flushes it at EOF -- which is precisely the defect the
    poll path had. So this one asserts on arrival times: several log frames,
    separated by real time, while the run is still going.
    """
    client = demo_server(_TICKING_SCRIPT)
    run_id = _start_run(client)

    with client.stream(
        "GET", _STREAM_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)
    ) as response:
        assert response.status_code == 200
        frames = _read_frames(response)

    log_frames = [frame for frame in frames if frame.event == "log"]
    assert len(log_frames) >= 3, (
        f"the script printed ten lines over 2.5s but arrived in {len(log_frames)} "
        "frame(s). One frame means the stream batched the whole run."
    )
    spread = log_frames[-1].at - log_frames[0].at
    assert spread >= 0.5, (
        f"every log frame arrived within {spread:.3f}s of the first, so the run's "
        "output was assembled and flushed rather than pushed as it was produced"
    )
    assert frames[-1].event == "end"


def test_stream_is_an_event_stream_that_ends_with_a_terminal_event(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    client = demo_server(_TICKING_SCRIPT)
    run_id = _start_run(client)

    with client.stream(
        "GET", _STREAM_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)
    ) as response:
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/event-stream")
        assert response.headers["cache-control"] == "no-cache, no-transform"
        # nginx's own per-response opt-out, carried by the response so the
        # stream states its requirement even behind a proxy nobody edited.
        assert response.headers["x-accel-buffering"] == "no"
        frames = _read_frames(response)

    end_frames = [frame.data for frame in frames if frame.event == "end"]
    assert _logs(frames), "a run that printed ten lines produced no log events"
    assert len(end_frames) == 1
    assert frames[-1].event == "end", "the terminal event must be last"

    end = end_frames[0]
    assert end["run_id"] == run_id
    assert end["eof"] is True
    assert end["chunk"] == ""
    assert end["status"] == "succeeded"
    assert end["exit_code"] == 0
    assert end["next_offset"] == end["offset"]
    for payload in _logs(frames):
        assert payload["run_id"] == run_id
        assert payload["eof"] is False
        assert payload["truncated"] is False


def test_streamed_chunks_reassemble_into_exactly_what_the_poll_endpoint_has(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    """One capture, two readers -- so the two readers must agree exactly."""
    client = demo_server(_TICKING_SCRIPT)
    run_id = _start_run(client)

    with client.stream(
        "GET", _STREAM_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)
    ) as response:
        frames = _read_frames(response)

    streamed = _streamed_text(frames)
    assert streamed == _whole_log(client, run_id)
    assert streamed.count("tick ") == 10


def test_reconnecting_at_the_last_next_offset_has_no_gap_and_no_repeat(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    """The property that makes a dropped connection cheap.

    Asserted end to end -- the two halves are concatenated and compared against
    the finished log -- rather than by checking the arithmetic of the offset
    fields, which would pass just as happily if both halves were wrong in the
    same direction.
    """
    client = demo_server(_LONG_SCRIPT)
    run_id = _start_run(client)

    first_half = ""
    resume_at = 0
    with client.stream(
        "GET", _STREAM_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)
    ) as response:
        # Two frames in, then walk away while the script is still ticking.
        for frame in _read_frames(response, stop_after=None, max_frames=2):
            if frame.event == "log":
                assert frame.data["offset"] == resume_at, "a chunk began somewhere other than the cursor"
                first_half += frame.data["chunk"]
                resume_at = frame.data["next_offset"]

    assert resume_at > 0, "no bytes were delivered before the client disconnected"
    assert _run_status(client, run_id) == "running", "the run ended before the reconnect was tested"

    with client.stream(
        "GET",
        _STREAM_PATH.format(run_id=run_id),
        headers=_bearer(SUPERADMIN_SUBJECT),
        params={"offset": resume_at},
    ) as response:
        frames = _read_frames(response)

    assert _logs(frames)[0]["offset"] == resume_at
    assert first_half + _streamed_text(frames) == _whole_log(client, run_id)


def test_abandoned_clients_do_not_accumulate(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    """Proven, not assumed.

    A generator still polling after the browser closed its tab is invisible
    until a demo pod has accumulated dozens of them. demo_runner counts open
    streams for exactly this assertion; the thread count is checked alongside
    it because the counter would not notice a stray Timer or worker.

    Five connect-and-abandon cycles, and the state must be back where it
    started EACH time and while the run is still going -- an implementation
    that only cleans up when the run ends would pass a single-cycle test.
    """
    client = demo_server(_LONG_SCRIPT)
    run_id = _start_run(client)
    assert demo_runner._open_log_streams == 0

    threads_after_first_cycle = 0
    for cycle in range(5):
        with client.stream(
            "GET", _STREAM_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)
        ) as response:
            # The line iterator is held in a local on purpose. Letting go of
            # httpx's iterator is ITSELF a disconnect -- collecting it closes
            # the response -- so sampling the counter after handing the
            # iterator to a helper that returned would race the very cleanup
            # this test exists to observe, and fail intermittently against a
            # perfectly correct server.
            stream_lines = response.iter_lines()
            assert next(stream_lines).startswith("event:")
            assert demo_runner._open_log_streams == 1, "the stream under test never registered"
            # Leaving the with-block closes the response: the browser tab shutting.

        # The disconnect is noticed inside the event loop on the generator's
        # next write, so allow it a moment to land -- but only a moment.
        deadline = time.monotonic() + 10
        while demo_runner._open_log_streams != 0 and time.monotonic() < deadline:
            time.sleep(0.02)

        open_streams = demo_runner._open_log_streams
        # Order matters: read the count first, the run status second. Status
        # only moves forwards, so a "running" reading taken afterwards proves
        # the run was also running when the count was read -- which is what
        # makes this a cleanup-on-disconnect assertion rather than a
        # cleanup-eventually one.
        assert open_streams == 0, (
            f"cycle {cycle}: the SSE generator was still running after the client "
            "disconnected; every abandoned browser tab leaks a poller into the pod"
        )
        assert _run_status(client, run_id) == "running", "the run ended before the cycles finished"

        # anyio creates a worker thread or two servicing the first requests;
        # what matters is that the count stops growing, which is what a leak
        # would not do.
        if cycle == 0:
            threads_after_first_cycle = threading.active_count()
        else:
            assert threading.active_count() <= threads_after_first_cycle, (
                f"cycle {cycle}: thread count grew from {threads_after_first_cycle} "
                f"to {threading.active_count()} across abandoned streams"
            )

    _wait_for_terminal_run(client, run_id)


def test_an_already_finished_run_streams_the_remainder_and_closes(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    """The obvious hang: nothing more will ever be written, so waiting is fatal."""
    client = demo_server(_TICKING_SCRIPT)
    run_id = _start_run(client)
    assert _wait_for_terminal_run(client, run_id) == "succeeded"

    started_at = time.monotonic()
    with client.stream(
        "GET", _STREAM_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)
    ) as response:
        frames = _read_frames(response, deadline_seconds=15)
    elapsed = time.monotonic() - started_at

    assert frames[-1].event == "end"
    assert frames[-1].data["status"] == "succeeded"
    assert _streamed_text(frames) == _whole_log(client, run_id)
    # A finished run has nothing to wait for, so this is bounded by the size of
    # the buffer, not by the poll interval.
    assert elapsed < 5, f"a finished run took {elapsed:.1f}s to stream and close"
    assert demo_runner._open_log_streams == 0


def test_an_idle_stream_sends_keepalive_comments(
    demo_server: Callable[[str], httpx.Client], monkeypatch: pytest.MonkeyPatch
) -> None:
    """Demo phase 2 waits up to 300s for a Job while printing nothing.

    Without a keepalive the connection is silent for longer than an idle proxy
    tolerates and gets dropped mid-phase. The interval is shortened here rather
    than waiting 15s for the real one; what is under test is that the silence
    gets filled at all.
    """
    monkeypatch.setattr(demo_runner, "_SSE_KEEPALIVE_SECONDS", 0.1)
    client = demo_server(_SILENT_SCRIPT)
    run_id = _start_run(client)

    with client.stream(
        "GET", _STREAM_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)
    ) as response:
        frames = _read_frames(response, deadline_seconds=20)

    comments = [frame for frame in frames if frame.event == "comment"]
    assert comments, "an idle stream sent nothing at all while the script slept"
    # A bare comment line is what every EventSource client ignores; anything
    # else would surface in the browser as an unrecognised event.
    assert all(frame.data.startswith(":") for frame in comments)
    assert frames[-1].event == "end"
    assert _streamed_text(frames) == "finally something\n"


@pytest.mark.parametrize(
    ("chunk", "more_bytes_expected", "expected_head", "expected_held"),
    [
        # Nothing to hold back.
        (b"plain ascii\n", True, b"plain ascii\n", b""),
        ("✅ done\n".encode("utf-8"), True, "✅ done\n".encode("utf-8"), b""),
        # A character cut in half by a read boundary: hold the tail, decode the
        # rest, and let the next pass complete it.
        (b"ok \xe2\x9c", True, b"ok ", b"\xe2\x9c"),
        (b"ok \xf0\x9f\x94", True, b"ok ", b"\xf0\x9f\x94"),
        (b"\xe2\x9c", True, b"", b"\xe2\x9c"),
        # Genuinely malformed bytes are NOT an incomplete character, even when
        # they sit at the very end. Holding those back would park them until
        # the run ended, waiting for a continuation that is never coming, so
        # they pass through to errors="replace" -- exactly what /log does.
        (b"bad \xff\xfe more\n", True, b"bad \xff\xfe more\n", b""),
        (b"trailing garbage \xff", True, b"trailing garbage \xff", b""),
        (b"lead byte then garbage \xe2\xff", True, b"lead byte then garbage \xe2\xff", b""),
        # Once the run is over nothing more can arrive, so there is nothing to
        # wait for and a truncated tail is decoded as-is.
        (b"ok \xe2\x9c", False, b"ok \xe2\x9c", b""),
    ],
)
def test_decodable_prefix_holds_back_only_an_incomplete_trailing_character(
    chunk: bytes, more_bytes_expected: bool, expected_head: bytes, expected_held: bytes
) -> None:
    """The split-character rule, at the seam where it is deterministic.

    The end-to-end test below cannot reliably produce a split: it needs the
    stream's poll to observe run._log at the exact instant the monitor thread's
    last append ended mid-character. That happens in production over a long
    phase of unicode-heavy kubectl output, and essentially never inside a
    two-second test. Asserting the rule directly is the difference between
    covering this code and merely running it.
    """
    head, held = demo_runner._decodable_prefix(chunk, more_bytes_expected=more_bytes_expected)

    assert head == expected_head
    assert held == expected_held
    # Whatever the split, no byte may be invented or lost.
    assert head + held == chunk


def test_a_character_split_across_two_polls_is_delivered_whole(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The same rule through the generator, with the race forced.

    A synthetic run whose buffer grows one byte at a time, polled several times
    per byte -- the pathological version of what the monitor thread does
    occasionally. The assertion is on the generator's own output rather than on
    the helper it calls, so a correct helper wired up wrongly still fails.
    """
    monkeypatch.setattr(demo_runner, "_SSE_POLL_SECONDS", 0.001)
    text = "✅ crédential 🔐\n"
    encoded = text.encode("utf-8")
    run = _synthetic_run()

    async def _drive() -> list[_Frame]:
        async def _feed_one_byte_at_a_time() -> None:
            for index in range(len(encoded)):
                await asyncio.sleep(0.005)
                with run._lock:
                    run._log.extend(encoded[index : index + 1])
            run.exit_code = 0
            run.status = "succeeded"

        feeder = asyncio.create_task(_feed_one_byte_at_a_time())
        frames = [
            _parse_frame(raw) async for raw in demo_runner._iter_run_log_events(run, 0)
        ]
        await feeder
        return frames

    frames = asyncio.run(_drive())
    streamed = _streamed_text(frames)

    assert "�" not in streamed, "a multi-byte character was destroyed at a poll boundary"
    assert streamed == text
    # And the offsets still describe the raw bytes, not the characters.
    assert frames[-1].data["next_offset"] == len(encoded)


def test_multibyte_characters_survive_a_real_burst(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    """The end-to-end half: ~25KB of unicode through a real socket.

    Fidelity under load rather than a targeted split -- see the two tests above
    for the split rule itself, which this one cannot deterministically trigger.
    """
    client = demo_server(_UNICODE_SCRIPT)
    run_id = _start_run(client)

    with client.stream(
        "GET", _STREAM_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)
    ) as response:
        frames = _read_frames(response)

    streamed = _streamed_text(frames)
    assert "�" not in streamed, "a multi-byte character was destroyed at a chunk boundary"
    assert streamed == _EXPECTED_UNICODE
    assert streamed == _whole_log(client, run_id)


def test_stream_requires_superadmin_not_merely_authentication(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    """Same gate as /log. The transport changed; the audience did not."""
    client = demo_server(_TICKING_SCRIPT)
    run_id = _start_run(client)
    _wait_for_terminal_run(client, run_id)

    anonymous = client.get(_STREAM_PATH.format(run_id=run_id))
    non_superadmin = client.get(
        _STREAM_PATH.format(run_id=run_id), headers=_bearer(NON_SUPERADMIN_SUBJECT)
    )

    assert anonymous.status_code == 401
    assert non_superadmin.status_code == 403
    assert non_superadmin.json()["error"]["code"] == "superadmin_required"
    # Not a stream that happens to carry an error: the refusal is a plain JSON
    # response, decided before a single byte of a 200 could be committed.
    assert not non_superadmin.headers["content-type"].startswith("text/event-stream")
    assert demo_runner._open_log_streams == 0


def test_bad_requests_are_refused_before_the_stream_starts(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    """Once a 200 is on the wire an error can only arrive as an event nobody parses."""
    client = demo_server(_TICKING_SCRIPT)
    run_id = _start_run(client)
    _wait_for_terminal_run(client, run_id)

    negative_offset = client.get(
        _STREAM_PATH.format(run_id=run_id),
        headers=_bearer(SUPERADMIN_SUBJECT),
        params={"offset": -1},
    )
    unknown_run = client.get(
        _STREAM_PATH.format(run_id="does-not-exist"), headers=_bearer(SUPERADMIN_SUBJECT)
    )

    assert negative_offset.status_code == 422
    assert negative_offset.json()["error"]["code"] == "invalid_log_offset"
    assert unknown_run.status_code == 404
    assert unknown_run.json()["error"]["code"] == "run_not_found"
    assert demo_runner._open_log_streams == 0


def test_the_poll_endpoint_is_unaffected_by_an_attached_stream(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    """The stream is additive. A client that ignores it must notice nothing.

    Not a restatement of tests/test_demo_runner.py's paging test: this runs the
    poll protocol WHILE an SSE client is attached to the same run, because "one
    capture, two readers" is only true if the second reader consumes nothing. A
    reader that drained the buffer would leave the poll client short, and every
    existing test would still pass because none of them hold a stream open.
    """
    client = demo_server(_TICKING_SCRIPT)
    run_id = _start_run(client)

    with client.stream(
        "GET", _STREAM_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)
    ) as response:
        _read_frames(response, stop_after=None, max_frames=2)
        assert _wait_for_terminal_run(client, run_id) == "succeeded"
        first_page = client.get(
            _LOG_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)
        ).json()

    assert first_page["offset"] == 0
    assert first_page["eof"] is True
    assert first_page["truncated"] is False
    assert first_page["chunk"].count("tick ") == 10
    assert first_page["next_offset"] == len(first_page["chunk"].encode("utf-8"))


# The dashboard's src/api/demoRunnerSseContract.test.ts replays a transcript
# captured from this endpoint and asserts the client reassembles it. That test
# is only worth having while the transcript still resembles what we emit, and a
# fixture nobody re-derives is a fixture that quietly describes last quarter's
# wire format.
_CLIENT_FIXTURE = (
    Path(__file__).resolve().parents[3]
    / "dashboard-signalloom/src/api/__fixtures__/sse-transcript.txt"
)


def test_the_transcript_the_dashboard_is_tested_against_still_describes_us(
    demo_server: Callable[[str], httpx.Client]
) -> None:
    """The two halves of the SSE path must not drift apart in silence.

    Nothing else joins them. This module tests the emitter against Python
    assertions; the dashboard tests its parser against strings; the acceptance
    harness drives the real components against a handwritten SSE *double* — and
    that double shipped emitting `event: chunk` while the client dispatches on
    `log`. The stream connected, delivered every byte, and displayed nothing.
    The spec passed anyway, because the client fell back to polling.

    So this asserts the shape the client is compiled against, not the bytes:
    run ids and timings differ every run, and pinning those would make this a
    test of the capture rather than of the contract.
    """
    fixture = _CLIENT_FIXTURE.read_text(encoding="utf-8")
    client = demo_server(_TICKING_SCRIPT)
    run_id = _start_run(client)
    with client.stream("GET", _STREAM_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT)) as response:
        assert response.status_code == 200
        frames = _read_frames(response)

    events = [frame.event for frame in frames if frame.event != "comment"]
    assert events[0] == "log", f"the fixture's first event is `log`; we emitted {events[0]!r}"
    assert events[-1] == "end", f"the fixture terminates with `end`; we emitted {events[-1]!r}"
    assert "event: log\n" in fixture and "event: end\n" in fixture, (
        "the committed transcript no longer names the events this endpoint emits — "
        "re-capture it, or the dashboard's contract test is asserting against fiction"
    )

    # Field sets, not values. A key added here is fine; a key REMOVED or renamed
    # is what breaks a client that destructures it.
    fixture_log_keys = {
        key
        for line in fixture.splitlines()
        if line.startswith("data: ") and '"eof": false' in line
        for key in json.loads(line[len("data: ") :])
    }
    emitted_log_keys = set(_logs(frames)[0])
    assert fixture_log_keys <= emitted_log_keys, (
        f"the transcript carries keys we no longer emit: {fixture_log_keys - emitted_log_keys}"
    )

    fixture_end_keys = {
        key
        for line in fixture.splitlines()
        if line.startswith("data: ") and '"eof": true' in line
        for key in json.loads(line[len("data: ") :])
    }
    emitted_end_keys = set(frames[-1].data)
    assert fixture_end_keys <= emitted_end_keys, (
        f"the terminal frame lost keys the client reads: {fixture_end_keys - emitted_end_keys}"
    )
