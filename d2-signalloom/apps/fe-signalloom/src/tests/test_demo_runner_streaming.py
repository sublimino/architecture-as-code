"""The demo script's output must reach the log WHILE the script is running.

The defect these tests exist to catch: nothing streamed. The dashboard polls
``GET /runs/{id}/log?offset=N`` every 500ms and renders the result in a
purpose-built streaming console, and that console stayed empty for the whole of
a multi-minute run, then filled in one jump at the end.

Root cause was one character in ``_monitor_run``: ``proc.stdout.read(8192)``.
``BufferedReader.read(n)`` is a fill-EXACTLY-n read -- it loops on the raw pipe
until it has n bytes or hits EOF. A demo phase prints a few hundred bytes of
banner and then blocks on kubectl for minutes, so the first byte only reached
``run._log`` when the child exited and the pipe closed. Measured against a
script printing a line every 250ms for 3s:

    read(8192)   -> 1 chunk delivered at 3.01s
    read1(8192)  -> 12 chunks at 0.00s, 0.25s, 0.50s ... 2.76s

Why this file, when tests/test_demo_runner.py already covered the log:

  Every existing log assertion is of the form "after the run finishes, the log
  contains the expected text". That assertion is exactly as true of a batching
  implementation as of a streaming one -- it went green throughout the entire
  period the feature was broken. Correctness here is a WALL-CLOCK property, so
  these tests assert on when bytes are observable, not on what they say.

The second buffering hop these tests pin is the child's own stdio. Shell
builtins write(2) straight through and Go tools (kubectl) do not buffer a pipe,
but CPython block-buffers a non-tty stdout at 8KiB, so a Python step in the
script chain would reintroduce the identical symptom one process further down.
"""
from __future__ import annotations

import select
import subprocess
import sys
import threading
import time
from contextlib import ExitStack
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Callable, Iterator, cast

import pytest
from fastapi.testclient import TestClient

import api_compat
import demo_runner
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

# The token machinery, the fake JWK client and the ready-pool stub are imported
# rather than reimplemented: they are already proven in the suite's main
# demo-runner file, and a second copy of a JWT fixture is a second thing to keep
# in step with the issuer settings.
from test_demo_runner import (
    SUBJECT_TENANTS,
    SUPERADMIN_EMAIL,
    SUPERADMIN_SUBJECT,
    _bearer,
    _ReadyPool,
    _TestJWKClient,
)

# ~3s of output in 12 observable instalments. Long enough that a sampling loop
# gets several mid-run reads on a loaded machine, short enough to keep the suite
# fast. The tick payload is deliberately tiny -- a few hundred bytes total, far
# under the 8192-byte read size, which is the whole point: the old code could
# not deliver ANY of it until EOF.
_TICK_COUNT = 12
_TICK_INTERVAL_SECONDS = 0.25
_TICKING_SCRIPT = (
    "#!/usr/bin/env bash\n"
    f"for i in $(seq 1 {_TICK_COUNT}); do\n"
    "  printf 'tick %02d\\n' \"$i\"\n"
    f"  sleep {_TICK_INTERVAL_SECONDS}\n"
    "done\n"
)

# One burst, ~58KB, emitted as fast as bash can print it -- comfortably more
# than one 8192-byte read. Every line is numbered so a dropped or reordered
# partial read is visible in the assertion, not just a length mismatch.
_BURST_LINES = 2000
_BURST_SCRIPT = (
    "#!/usr/bin/env bash\n"
    f"for i in $(seq 1 {_BURST_LINES}); do\n"
    "  printf 'burst-%05d-abcdefghijklmnop\\n' \"$i\"\n"
    "done\n"
)
_EXPECTED_BURST = "".join(
    f"burst-{index:05d}-abcdefghijklmnop\n" for index in range(1, _BURST_LINES + 1)
).encode("utf-8")


@pytest.fixture(autouse=True)
def reset_demo_runner_state() -> Iterator[None]:
    demo_runner.reset_state_for_testing()
    yield
    demo_runner.reset_state_for_testing()


@pytest.fixture
def demo_client(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> Iterator[Callable[[str], TestClient]]:
    """A TestClient whose demo script is chosen per test.

    The suite's shared client fixture hardcodes one fake script; timing tests
    need a script whose emission schedule they control, so this one takes the
    body as an argument.
    """
    stack = ExitStack()

    def _make(script_body: str) -> TestClient:
        script_path = tmp_path / "streaming-demo.sh"
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


def _wait_for_terminal_run(client: TestClient, run_id: str) -> dict[str, Any]:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        response = client.get(
            f"/api/demo/supercred/runs/{run_id}", headers=_bearer(SUPERADMIN_SUBJECT)
        )
        payload = response.json()
        if payload["status"] != "running":
            return cast(dict[str, Any], payload)
        time.sleep(0.05)
    raise AssertionError(f"run {run_id} did not finish before deadline")


def test_log_has_bytes_in_it_before_the_child_exits(
    demo_client: Callable[[str], TestClient]
) -> None:
    """The load-bearing assertion: output is observable DURING the run.

    Sampling order matters and is deliberate. The length is read first and the
    status second, because status only ever moves forwards (running -> one of
    the terminal states). If the status still said "running" at T2, then it
    also said "running" at the earlier T1 when the non-zero length was read --
    so bytes provably existed while the child was alive. Reading them the other
    way round would leave the pass open to bytes that landed at EOF.
    """
    client = demo_client(_TICKING_SCRIPT)
    run_id = _start_run(client)
    run = demo_runner._runs[run_id]

    observed_bytes_while_running = 0
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        with run._lock:
            log_length = len(run._log)
        still_running = run.status == "running"
        if log_length > 0 and still_running:
            observed_bytes_while_running = log_length
            break
        if not still_running:
            break
        time.sleep(0.02)

    assert observed_bytes_while_running > 0, (
        "the demo script's output only became visible after the child exited. "
        "The dashboard's streaming console shows nothing for the whole of a "
        "multi-minute phase and then fills in one jump. Check that "
        "_monitor_run reads the pipe with a first-availability read (read1), "
        "not the fill-exactly-n BufferedReader.read."
    )

    finished = _wait_for_terminal_run(client, run_id)
    assert finished["status"] == "succeeded"


def test_log_grows_across_several_mid_run_samples(
    demo_client: Callable[[str], TestClient]
) -> None:
    """Not just "something arrived early" -- it keeps arriving, incrementally.

    A single early chunk would also be produced by an implementation that
    delivered the first partial read and then batched the rest, so this samples
    the log through the polling endpoint the dashboard actually calls and
    requires several distinct, strictly increasing mid-run lengths.
    """
    client = demo_client(_TICKING_SCRIPT)
    run_id = _start_run(client)
    run = demo_runner._runs[run_id]

    mid_run_lengths: list[int] = []
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        log_response = client.get(
            f"/api/demo/supercred/runs/{run_id}/log", headers=_bearer(SUPERADMIN_SUBJECT)
        )
        assert log_response.status_code == 200
        length = len(log_response.json()["chunk"])
        # Same ordering rule as the test above: sample the payload first, then
        # decide whether the sample counts as mid-run.
        if run.status != "running":
            break
        mid_run_lengths.append(length)
        time.sleep(0.15)

    # Consecutive-duplicate removal: the sampler runs faster than the script
    # ticks, so repeats are expected and only the transitions carry meaning.
    growth = [
        length
        for index, length in enumerate(mid_run_lengths)
        if index == 0 or length != mid_run_lengths[index - 1]
    ]

    assert mid_run_lengths == sorted(mid_run_lengths), (
        f"the log shrank between samples, which should be impossible: {mid_run_lengths}"
    )
    assert len(growth) >= 3, (
        "expected the log to grow at three or more distinct points during the "
        f"run; observed lengths {mid_run_lengths}. A single step from 0 to the "
        "full output is the batching failure this file exists to catch."
    )

    finished = _wait_for_terminal_run(client, run_id)
    assert finished["status"] == "succeeded"


def test_a_burst_larger_than_the_read_size_is_captured_byte_for_byte(
    demo_client: Callable[[str], TestClient]
) -> None:
    """Streaming must not cost fidelity.

    A first-availability read returns short chunks at arbitrary boundaries, so
    the risk it introduces is a dropped or reordered partial. ~58KB in one
    burst crosses the 8192-byte read size many times over; every line is
    numbered, so the comparison localises any loss rather than just reporting a
    length mismatch.
    """
    client = demo_client(_BURST_SCRIPT)
    run_id = _start_run(client)
    finished = _wait_for_terminal_run(client, run_id)
    assert finished["status"] == "succeeded"

    run = demo_runner._runs[run_id]
    with run._lock:
        captured = bytes(run._log)
        truncated = run._log_truncated

    assert not truncated
    assert len(captured) == len(_EXPECTED_BURST)
    assert captured == _EXPECTED_BURST


# A phase that leaves a grandchild holding the log pipe and then exits. Nothing
# in scripts/supercred-demo.sh does this today -- its one background command
# (kubectl port-forward, line 302) redirects both streams to /dev/null, so it
# does not inherit the pipe -- but it is one forgotten redirect away.
_ORPHAN_HOLDS_PIPE_SCRIPT = (
    "#!/usr/bin/env bash\n"
    "echo phase-banner\n"
    "sleep 300 &\n"   # inherits stdout: the pipe stays open after this shell exits
    "exit 0\n"
)


def test_cancelling_releases_a_reader_a_grandchild_has_pinned_open(
    demo_client: Callable[[str], TestClient]
) -> None:
    """EOF is not guaranteed by the direct child exiting.

    A grandchild that inherited stdout keeps the pipe's write end open, so the
    monitor thread's read parks indefinitely even though the process it is
    nominally following has already finished. If the reader's exit depended
    solely on EOF, an aborted run would leak a blocked thread forever.

    It does not: cancellation signals the whole process group, which kills the
    grandchild too and closes the last write end. Measured directly -- a
    blocking read1 returns b"" within a millisecond of the killpg. This test
    pins the end-to-end consequence, that a cancelled run in this shape still
    reaches a terminal state promptly rather than sitting until the 900s
    timeout.
    """
    client = demo_client(_ORPHAN_HOLDS_PIPE_SCRIPT)
    run_id = _start_run(client)

    # The banner arrives, and then nothing: the shell has exited but the read
    # cannot see EOF, so the run stays "running" with a dead child.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        payload = client.get(
            f"/api/demo/supercred/runs/{run_id}/log", headers=_bearer(SUPERADMIN_SUBJECT)
        ).json()
        if "phase-banner" in payload["chunk"]:
            break
        time.sleep(0.02)
    assert "phase-banner" in payload["chunk"]

    reset = client.post("/api/demo/supercred/reset", headers=_bearer(SUPERADMIN_SUBJECT))
    assert reset.status_code == 202

    cancelled = _wait_for_terminal_run(client, run_id)
    assert cancelled["status"] == "cancelled"


class _StubPipe:
    """A pipe that returns a scripted sequence, including None."""

    def __init__(self, reads: list[bytes | None]) -> None:
        self._reads = list(reads)
        self.closed = False

    def read1(self, size: int) -> bytes | None:
        del size
        return self._reads.pop(0) if self._reads else b""

    def close(self) -> None:
        self.closed = True


class _StubProcess:
    def __init__(self, stdout: _StubPipe) -> None:
        self.stdout = stdout

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        return 0

    def poll(self) -> int:
        return 0


def _run_with_stubbed_pipe(reads: list[bytes | None]) -> Any:
    run_lock = threading.Lock()
    return demo_runner._Run(
        run_id="stubbed-pipe-run",
        step_id="1",
        kind="step",
        status="running",
        started_at=datetime.now(UTC),
        finished_at=None,
        exit_code=None,
        error=None,
        _process=cast(Any, _StubProcess(_StubPipe(reads))),
        _log=bytearray(),
        _log_truncated=False,
        _timed_out=False,
        _lock=run_lock,
        _log_changed=threading.Condition(run_lock),
        _done=threading.Event(),
    )


def test_a_none_read_is_not_end_of_file() -> None:
    """None and b"" are different answers, and `if not chunk` conflates them.

    read1 returns None -- not b"" -- when the fd is non-blocking and has
    nothing ready this instant. b"" is the one that means the write end is
    gone. Nothing in the runner sets O_NONBLOCK today, so this is a guard
    rather than a live bug; it is worth a test because the failure it prevents
    is silent. Reading None as EOF would stop the capture at whatever had
    arrived and then report the run succeeded, and a truncated log is
    indistinguishable from a short one at every layer above.
    """
    run = _run_with_stubbed_pipe([b"first ", None, b"second", b""])

    demo_runner._monitor_run(run)

    with run._lock:
        captured = bytes(run._log)
    assert captured == b"first second", (
        "output after a None read was dropped, so a non-blocking pipe would "
        "silently truncate the log at the first moment it had nothing ready"
    )
    assert run.status == "succeeded"
    assert run.exit_code == 0


def test_a_python_child_is_told_not_to_block_buffer_its_output() -> None:
    """The second buffering hop: fixing the parent's read is not enough.

    CPython block-buffers stdout at 8KiB whenever it is not a tty, so a Python
    step anywhere in the demo script's chain would hold its output until exit
    and reproduce the original symptom one process further down -- with the
    parent now reading promptly and finding nothing to read.

    Asserted as a requirement (does a real child's output arrive early?) rather
    than as an assertion about which key is in the environment, so it stays
    true of whatever mechanism a future change uses to satisfy it.
    """
    child = subprocess.Popen(
        [
            sys.executable,
            "-c",
            # No flush=True, no -u: the child is written the naive way on
            # purpose, because that is how a step script would be written.
            "print('first line'); import time; time.sleep(3)",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        env=demo_runner._child_env(),
    )
    try:
        assert child.stdout is not None
        # 1.5s against a child that sleeps 3s: a block-buffered child cannot
        # possibly answer inside the window, an unbuffered one answers in
        # milliseconds. The gap is wide enough to survive a loaded machine.
        readable, _, _ = select.select([child.stdout], [], [], 1.5)
        assert readable, (
            "the demo script's child block-buffered its stdout: nothing was "
            "readable 1.5s into a child that printed immediately and then slept "
            "3s. The runner's fixed child environment must force unbuffered "
            "output (PYTHONUNBUFFERED)."
        )
        assert child.stdout.read1(8192).startswith(b"first line")
    finally:
        child.kill()
        child.wait(timeout=10)
        if child.stdout is not None:
            child.stdout.close()
