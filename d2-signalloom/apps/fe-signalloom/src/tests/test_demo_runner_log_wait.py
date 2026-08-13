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
