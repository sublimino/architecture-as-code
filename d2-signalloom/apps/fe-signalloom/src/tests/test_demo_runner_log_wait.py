"""GET /log?wait= must deliver bytes as they are produced, not on a timer.

The read1 fix made the runner capture the script's output as it appears. It did
nothing about the second half of the latency: the dashboard polls every 500ms,
so a byte captured instantly still waits up to a full poll interval before any
human sees it, and the console advances in visible steps regardless of how fast
the producer is.

`wait` closes that gap without adding a transport. A caller already at the end
of the buffer parks server-side until new bytes arrive, the run ends, or its
deadline passes. The response is an ordinary short HTTP response — which is the
entire point. It is immune to proxy buffering, gzip block-filling, HTTP/1.0
upstreams, compressor filters and inspecting proxies: every layer that can
swallow a stream and leave a blank console with no error to debug. It travels
the path we already know works, because the poll endpoint has been working
across it all along.

Two properties carry the design and both are asserted here:

  * OFF BY DEFAULT. `wait` omitted must be byte-for-byte the endpoint's
    original behaviour, because that behaviour is a tested contract and an
    existing client must not be able to tell this shipped.
  * IT MUST NOT PARK THE EVENT LOOP. A blocking wait on the event loop would
    stall every other request in the pod — turning a latency improvement into
    an outage the moment two people open the dashboard.
"""
from __future__ import annotations

import threading
import time
from contextlib import ExitStack
from pathlib import Path
from typing import Any, Callable, Iterator, cast

import pytest
from fastapi.testclient import TestClient

import api_compat
import demo_runner
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

from test_demo_runner import (
    SUBJECT_TENANTS,
    SUPERADMIN_EMAIL,
    SUPERADMIN_SUBJECT,
    _bearer,
    _ReadyPool,
    _TestJWKClient,
)

_LOG_PATH = "/api/demo/supercred/runs/{run_id}/log"

# Prints, goes quiet for a beat, prints again. The gap is the thing under test:
# a waiting caller must be released by the second write, not by its own timer.
_GAP_SCRIPT = (
    "#!/usr/bin/env bash\n"
    "echo first\n"
    "sleep 1.0\n"
    "echo second\n"
    "sleep 5\n"
)

# Prints once and then says nothing at all for far longer than any wait in this
# file, so a wait against it can only end at its deadline.
_SILENT_AFTER_FIRST_SCRIPT = "#!/usr/bin/env bash\necho first\nsleep 30\n"

# Prints once, then exits without printing again. The end of a run is a
# transition a waiter is parked on just as much as new output is -- and it is
# the one a naive implementation misses, because the last thing a phase does is
# exit, not print.
_QUIET_EXIT_SCRIPT = "#!/usr/bin/env bash\necho first\nsleep 1.0\n"

_FIRST_LINE_BYTES = len(b"first\n")


@pytest.fixture(autouse=True)
def reset_demo_runner_state() -> Iterator[None]:
    demo_runner.reset_state_for_testing()
    yield
    demo_runner.reset_state_for_testing()


@pytest.fixture
def demo_client(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> Iterator[Callable[[str], TestClient]]:
    stack = ExitStack()

    def _make(script_body: str) -> TestClient:
        script_path = tmp_path / "wait-demo.sh"
        script_path.write_text(script_body, encoding="utf-8")
        script_path.chmod(0o755)

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
        return stack.enter_context(TestClient(app, raise_server_exceptions=False))

    try:
        yield _make
    finally:
        stack.close()
        set_pool_for_testing(None)


def _start_run(client: TestClient) -> str:
    response = client.post(
        "/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer(SUPERADMIN_SUBJECT)
    )
    assert response.status_code == 202
    return cast(str, response.json()["run_id"])


def _read_log(client: TestClient, run_id: str, **params: Any) -> dict[str, Any]:
    response = client.get(
        _LOG_PATH.format(run_id=run_id), headers=_bearer(SUPERADMIN_SUBJECT), params=params
    )
    assert response.status_code == 200
    return cast(dict[str, Any], response.json())


def _wait_until_first_line(client: TestClient, run_id: str) -> None:
    """Get to the state the test cares about: caught up, run still going."""
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if _read_log(client, run_id)["next_offset"] >= _FIRST_LINE_BYTES:
            return
        time.sleep(0.02)
    raise AssertionError("the script never produced its first line")


def test_a_waiting_caller_is_released_by_the_producer_not_by_its_own_timer(
    demo_client: Callable[[str], TestClient]
) -> None:
    """The property that removes the poll-interval floor."""
    client = demo_client(_GAP_SCRIPT)
    run_id = _start_run(client)
    _wait_until_first_line(client, run_id)

    started_at = time.monotonic()
    payload = _read_log(client, run_id, offset=_FIRST_LINE_BYTES, wait=20)
    elapsed = time.monotonic() - started_at

    assert payload["chunk"] == "second\n"
    assert payload["offset"] == _FIRST_LINE_BYTES
    assert payload["next_offset"] == _FIRST_LINE_BYTES + len(b"second\n")
    # The script writes ~1s after the first line. Returning anywhere near the
    # 20s deadline would mean the wait ended on its timer having missed the
    # write it was parked for.
    assert elapsed < 10, f"the waiter took {elapsed:.1f}s to notice a write made at ~1s"


def test_a_wait_with_nothing_to_report_returns_empty_at_its_deadline(
    demo_client: Callable[[str], TestClient]
) -> None:
    """A timed-out wait is an ordinary empty read, not an error."""
    client = demo_client(_SILENT_AFTER_FIRST_SCRIPT)
    run_id = _start_run(client)
    _wait_until_first_line(client, run_id)

    started_at = time.monotonic()
    payload = _read_log(client, run_id, offset=_FIRST_LINE_BYTES, wait=1)
    elapsed = time.monotonic() - started_at

    assert payload["chunk"] == ""
    assert payload["offset"] == _FIRST_LINE_BYTES
    assert payload["eof"] is False
    # It really waited rather than returning immediately...
    assert elapsed >= 0.9, f"the wait returned after {elapsed:.2f}s, so it never waited"
    # ...and it really stopped at the deadline rather than hanging on.
    assert elapsed < 15, f"the wait overran its 1s deadline by a long way: {elapsed:.1f}s"


def test_a_run_ending_quietly_releases_the_waiter(
    demo_client: Callable[[str], TestClient]
) -> None:
    """The transition a naive implementation misses.

    A waiter woken only by output sits out its entire deadline every time a
    phase ends, because the last thing a phase does is exit, not print. That is
    the end of every single run the dashboard shows.
    """
    client = demo_client(_QUIET_EXIT_SCRIPT)
    run_id = _start_run(client)
    _wait_until_first_line(client, run_id)

    started_at = time.monotonic()
    payload = _read_log(client, run_id, offset=_FIRST_LINE_BYTES, wait=20)
    elapsed = time.monotonic() - started_at

    assert payload["chunk"] == ""
    assert payload["eof"] is True, "the run had finished, so this read was the last one"
    assert elapsed < 10, (
        f"the waiter took {elapsed:.1f}s to notice a run that ended at ~1s; it is "
        "waking on output only, not on the run reaching a terminal state"
    )


def test_omitting_wait_keeps_the_original_non_blocking_behaviour(
    demo_client: Callable[[str], TestClient]
) -> None:
    """An existing client must not be able to tell this shipped."""
    client = demo_client(_SILENT_AFTER_FIRST_SCRIPT)
    run_id = _start_run(client)
    _wait_until_first_line(client, run_id)

    started_at = time.monotonic()
    without_wait = _read_log(client, run_id, offset=_FIRST_LINE_BYTES)
    explicit_zero = _read_log(client, run_id, offset=_FIRST_LINE_BYTES, wait=0)
    elapsed = time.monotonic() - started_at

    assert without_wait == explicit_zero
    assert without_wait["chunk"] == ""
    assert elapsed < 1.0, (
        f"two waitless reads against a silent run took {elapsed:.2f}s; the default "
        "must not block"
    )


def test_wait_is_capped_server_side(
    demo_client: Callable[[str], TestClient], monkeypatch: pytest.MonkeyPatch
) -> None:
    """A client cannot ask a worker thread to be held for as long as it likes."""
    monkeypatch.setattr(demo_runner, "_MAX_LOG_WAIT_SECONDS", 0.5)
    client = demo_client(_SILENT_AFTER_FIRST_SCRIPT)
    run_id = _start_run(client)
    _wait_until_first_line(client, run_id)

    started_at = time.monotonic()
    payload = _read_log(client, run_id, offset=_FIRST_LINE_BYTES, wait=9999)
    elapsed = time.monotonic() - started_at

    assert payload["chunk"] == ""
    assert elapsed < 10, f"a wait=9999 request was not capped: it took {elapsed:.1f}s"


def test_a_negative_wait_is_rejected(demo_client: Callable[[str], TestClient]) -> None:
    client = demo_client(_SILENT_AFTER_FIRST_SCRIPT)
    run_id = _start_run(client)

    response = client.get(
        _LOG_PATH.format(run_id=run_id),
        headers=_bearer(SUPERADMIN_SUBJECT),
        params={"wait": -1},
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_log_wait"


def test_a_wait_in_flight_does_not_stall_other_requests(
    demo_client: Callable[[str], TestClient]
) -> None:
    """The requirement that makes this safe to ship at all.

    If the wait ran on the event loop, one client sitting on a quiet phase
    would freeze the whole pod. This parks a real waiter and then asks the same
    app for something unrelated, from another thread, while it is parked.
    """
    client = demo_client(_SILENT_AFTER_FIRST_SCRIPT)
    run_id = _start_run(client)
    _wait_until_first_line(client, run_id)

    waiter_finished = threading.Event()

    def _park() -> None:
        try:
            _read_log(client, run_id, offset=_FIRST_LINE_BYTES, wait=5)
        finally:
            waiter_finished.set()

    waiter = threading.Thread(target=_park, name="parked-log-waiter", daemon=True)
    waiter.start()
    try:
        # Let the waiter reach the point of actually blocking.
        time.sleep(0.5)
        assert not waiter_finished.is_set(), "the waiter did not park; test proves nothing"

        started_at = time.monotonic()
        status = client.get(
            f"/api/demo/supercred/runs/{run_id}", headers=_bearer(SUPERADMIN_SUBJECT)
        )
        elapsed = time.monotonic() - started_at

        assert status.status_code == 200
        assert elapsed < 3, (
            f"an unrelated request took {elapsed:.1f}s while one caller was waiting on "
            "a quiet log — the wait is holding the event loop"
        )
    finally:
        assert waiter_finished.wait(30), "the parked waiter never returned"
        waiter.join(timeout=10)


def test_a_finished_wait_leaves_no_thread_parked(
    demo_client: Callable[[str], TestClient]
) -> None:
    """A waiter cannot be cancelled mid-wait, so it must end at its deadline.

    That is the cost of doing this in a worker thread, and the cap is what
    bounds it. What must not happen is a thread that never comes back at all.
    """
    client = demo_client(_SILENT_AFTER_FIRST_SCRIPT)
    run_id = _start_run(client)
    _wait_until_first_line(client, run_id)

    _read_log(client, run_id, offset=_FIRST_LINE_BYTES, wait=1)
    threads_after_first_wait = threading.active_count()

    for _ in range(3):
        _read_log(client, run_id, offset=_FIRST_LINE_BYTES, wait=1)

    assert threading.active_count() <= threads_after_first_wait, (
        "repeated waits accumulated threads; a parked waiter is not being released"
    )


# Writes half of a "✓" (U+2713 is three bytes: e2 9c 93), pauses, then writes
# the rest. read1 hands the parent whatever the pipe holds, so a caller polling
# in that window sees a truncated character -- which is not a contrived case:
# phase 3's compliance summary prints ✅ and ❌ from a python3 heredoc, and a
# waiting caller is by construction always reading the live tail.
_SPLIT_CHARACTER_SCRIPT = (
    "#!/usr/bin/env bash\n"
    "for i in $(seq 1 6); do\n"
    "  printf 'check %s \\xe2\\x9c' \"$i\"\n"
    "  sleep 0.15\n"
    "  printf '\\x93 done\\n'\n"
    "  sleep 0.15\n"
    "done\n"
    "sleep 5\n"
)


def test_a_character_split_across_two_polls_survives_the_poll_path(
    demo_client: Callable[[str], TestClient]
) -> None:
    """The default transport must not burn a half-character to U+FFFD.

    /log used to reason that its page boundary falls only every 64KiB, so a
    multi-byte character straddling one was a curiosity worth accepting. `wait`
    falsified that: a waiting caller is released the instant new bytes land and
    reads to the end of the buffer, so the boundary is now wherever read1
    happened to stop -- every single poll, not every 64KiB.

    Measured before the fix: six ✓ characters became twelve U+FFFD. The raw
    buffer decoded cleanly the whole time, so nothing was lost in capture; the
    corruption was created by the endpoint, on the path the dashboard actually
    uses.
    """
    client = demo_client(_SPLIT_CHARACTER_SCRIPT)
    run_id = _start_run(client)

    seen = ""
    offset = 0
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        page = _read_log(client, run_id, offset=offset, wait=0.5)
        seen += page["chunk"]
        offset = page["next_offset"]
        if seen.count("done") >= 6:
            break

    assert "�" not in seen, (
        f"the poll path replaced a truncated character instead of holding it back: {seen!r}. "
        "An instructor sees mojibake where phase 3 printed ✅/❌."
    )
    assert seen.count("✓") == 6, f"characters went missing entirely: {seen!r}"


# Traps TERM and prints on the way out. The cleanup a teardown prints while it
# is being cancelled is exactly the output someone reaching for Reset wants --
# and it lands AFTER the status flips to "cancelled".
_TERM_TRAP_SCRIPT = (
    "#!/usr/bin/env bash\n"
    "cleanup() { echo 'cleanup begin'; sleep 0.4; echo 'cleanup end'; exit 0; }\n"
    "trap cleanup TERM\n"
    "echo starting\n"
    "sleep 30 &\n"
    "wait $!\n"
)


def test_a_cancelled_run_does_not_report_eof_before_its_child_stops_printing(
    demo_client: Callable[[str], TestClient]
) -> None:
    """`cancelled` is set on the way IN to the kill, not after the drain.

    Both transports used `status != "running"` as their end-of-stream test, so
    a reader tailing a Reset could be told eof while the script was still
    printing its TERM-trap cleanup — the one part of a teardown anybody reads.
    """
    client = demo_client(_TERM_TRAP_SCRIPT)
    run_id = _start_run(client)
    _wait_until_first_line(client, run_id)

    seen = ""
    offset = 0
    eof_at: str | None = None

    def cancel_shortly() -> None:
        time.sleep(0.2)
        demo_runner._cancel_active()

    threading.Thread(target=cancel_shortly, daemon=True).start()

    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        page = _read_log(client, run_id, offset=offset, wait=1.0)
        seen += page["chunk"]
        offset = page["next_offset"]
        if page["eof"]:
            eof_at = seen
            break

    assert eof_at is not None, "the reader never reached eof on a cancelled run"
    assert "cleanup end" in eof_at, (
        "eof was reported before the cancelled script finished printing. A reader "
        f"tailing Reset stops one moment before the interesting part. Saw: {eof_at!r}"
    )


def test_a_capped_log_still_reaches_eof_instead_of_wedging(
    demo_client: Callable[[str], TestClient], monkeypatch: pytest.MonkeyPatch
) -> None:
    """The cap closes the buffer while the script keeps running.

    Once `_LOG_CAP_BYTES` is reached nothing is ever appended again, but the
    status stays "running". Holding an incomplete trailing character back then
    waits for a continuation that cannot arrive: `next_offset` stops advancing,
    `eof` stays False, and the client polls the same offset forever receiving
    nothing and never being told it is done.
    """
    # A cap two bytes short of a whole ✓, so the buffer's last byte is half a
    # character and the hold-back has something to be wrong about.
    monkeypatch.setattr(demo_runner, "_LOG_CAP_BYTES", 24)
    client = demo_client(
        "#!/usr/bin/env bash\nprintf 'aaaaaaaaaaaaaaaaaaaaaa\\xe2\\x9c\\x93 and more\\n'\nsleep 30\n"
    )
    run_id = _start_run(client)

    offset = 0
    deadline = time.monotonic() + 15
    saw_eof = False
    stalled_reads = 0
    while time.monotonic() < deadline:
        page = _read_log(client, run_id, offset=offset, wait=0.5)
        if page["next_offset"] == offset:
            stalled_reads += 1
        offset = page["next_offset"]
        if page["eof"]:
            saw_eof = True
            break
        if stalled_reads > 6:
            break

    assert saw_eof, (
        "a capped log never reported eof while the script ran on, so the client "
        f"polls offset {offset} forever with nothing to show for it"
    )


def test_abandoned_waiters_cannot_starve_the_control_plane(
    demo_client: Callable[[str], TestClient]
) -> None:
    """A parked wait holds an anyio worker thread and cannot be cancelled.

    A browser tab closed mid-wait leaves the thread parked until its own
    deadline, so abandoned waiters accumulate at the rate tabs are closed. That
    pool is shared with POST /runs and POST /reset — exhaust it and Reset stops
    responding, on stage.
    """
    client = demo_client(_SILENT_AFTER_FIRST_SCRIPT)
    run_id = _start_run(client)
    _wait_until_first_line(client, run_id)

    barrier_errors: list[BaseException] = []

    def park() -> None:
        try:
            _read_log(client, run_id, offset=_FIRST_LINE_BYTES, wait=10.0)
        except BaseException as exc:  # noqa: BLE001 - recorded, asserted below
            barrier_errors.append(exc)

    threads = [threading.Thread(target=park, daemon=True) for _ in range(16)]
    for thread in threads:
        thread.start()
    time.sleep(1.0)

    # A concrete bound, not the module's own constant: comparing the observed
    # count against the value that produced it is a tautology that passes
    # however high someone raises the cap.
    ANYIO_DEFAULT_THREAD_LIMIT = 40
    held = demo_runner._log_waiters.held()
    assert held < ANYIO_DEFAULT_THREAD_LIMIT / 2, (
        f"{held} of 16 concurrent waits parked worker threads at once. The cap must "
        f"stay well under anyio's default limit of {ANYIO_DEFAULT_THREAD_LIMIT}, or "
        "parked waiters become the reason POST /runs and POST /reset have no thread."
    )
    assert demo_runner._MAX_CONCURRENT_LOG_WAITERS < ANYIO_DEFAULT_THREAD_LIMIT / 2, (
        "the cap has been raised to where abandoned waiters can starve the control plane"
    )

    # Over the cap the request must degrade to the non-blocking read it would
    # have been without `wait` -- more latency, never a stall and never an error.
    assert not barrier_errors, f"a capped-out waiter failed instead of degrading: {barrier_errors!r}"
    for thread in threads:
        thread.join(timeout=20)
