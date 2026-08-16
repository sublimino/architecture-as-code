"""Evidence for the wall-clock assertions in tests/test_demo_runner_stream_sse.py.

That file has thirteen wall-clock dependencies and runs under `-n auto
--dist worksteal` on a 24-core box, so every timing assertion in it competes
with twenty-three other workers. It failed fifteen tests once, has passed
eleven consecutive times since, and the failing run's output was never
captured. All that survived was a summary line -- which is to say, nothing.

This module exists so that does not happen twice. It changes no threshold and
decides no outcome; it only makes a failure carry the observations needed to
tell the two candidate explanations apart:

  STARVED BY LOAD -- frames DID arrive, just late or bunched; load average
    well above the CPU count; a large involuntary-context-switch delta (the
    kernel preempting us mid-assertion); wall time far exceeding the CPU time
    actually consumed.

  STREAMING GENUINELY BROKEN -- frames absent, or all of them landing at EOF,
    with load below the CPU count and few involuntary preemptions. The defect
    the file was written to catch (read(8192) batching) looks exactly like
    this and nothing like the above.

Those two readings are not separable from `assert spread >= 0.5`. They are
separable from the report `explain()` renders.

COST. Every assertion here stays in the `assert cond, evidence` form, whose
message expression Python evaluates only when the condition is false -- so a
passing run pays nothing at all. The one exception is `Probe.__init__`, which
takes a single getrusage(2) and a single read of /proc/loadavg (tens of
microseconds, once per test) BEFORE the timed window opens, to give the failure
report a baseline to subtract. Nothing here sleeps, and nothing here touches
the filesystem unless SSE_TIMING_LOG is set.

SAFETY. Every field is gathered through `_safe`, because a diagnostic that
raises replaces the real assertion message with its own traceback -- strictly
worse than having no diagnostic. Subprocess state is read from Popen's cached
`returncode` rather than `poll()`, so inspecting a run cannot race the monitor
thread's own reaping of the child.
"""
from __future__ import annotations

import json
import os
import resource
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Sequence

import demo_runner

# A unicode burst produces hundreds of frames; the shape of the timeline lives
# at its two ends, so the middle is elided rather than flooding the report.
_TIMELINE_HEAD = 8
_TIMELINE_TAIL = 8

_RULE = "-" * 74
_HEAVY = "=" * 74

# Off by default. When set, each Probe appends one JSON record on close, to
# `${SSE_TIMING_LOG}.{worker}.jsonl` -- per worker, so concurrent xdist
# processes cannot interleave partial lines into one another's output. CI
# archives the report directory per run, so pointing this at it retains the
# timings of a run that has already finished.
_ARTEFACT_ENV = "SSE_TIMING_LOG"

# Populated by every Probe constructed during a test, drained by the autouse
# fixture in the test module. Never read for pass/fail purposes.
_pending: list[Probe] = []


def _safe(fn: Callable[[], Any]) -> Any:
    """Call `fn`, never raising. A diagnostic must not mask the failure it explains."""
    try:
        return fn()
    except Exception as exc:  # noqa: BLE001 -- the whole point is to swallow everything
        return f"<{type(exc).__name__}: {exc}>"


@dataclass(frozen=True)
class _Sample:
    """One reading of the things that make a timing assertion miss."""

    at: float
    load: Any
    utime: float
    stime: float
    voluntary: int
    involuntary: int


def _sample() -> _Sample:
    # RUSAGE_CHILDREN is included because the thing being timed is a bash
    # script in a subprocess: its CPU is the run's CPU, and leaving it out
    # would make every report look like the test did nothing.
    me = _safe(lambda: resource.getrusage(resource.RUSAGE_SELF))
    kids = _safe(lambda: resource.getrusage(resource.RUSAGE_CHILDREN))

    def _add(field: str) -> Any:
        return _safe(lambda: getattr(me, field) + getattr(kids, field))

    return _Sample(
        at=time.monotonic(),
        load=_safe(os.getloadavg),
        utime=_add("ru_utime"),
        stime=_add("ru_stime"),
        voluntary=_add("ru_nvcsw"),
        involuntary=_add("ru_nivcsw"),
    )


def worker_id() -> str:
    return os.environ.get("PYTEST_XDIST_WORKER", "master")


def worker_count() -> str:
    return os.environ.get("PYTEST_XDIST_WORKER_COUNT", "1")


def _usable_cpus() -> Any:
    return _safe(lambda: len(os.sched_getaffinity(0)))


def _delta(new: float, old: float) -> Any:
    return _safe(lambda: new - old)


def _secs(value: Any) -> str:
    """Seconds to three places, passing through whatever `_safe` substituted."""
    return f"{value:.3f}" if isinstance(value, (int, float)) else str(value)


def _loads(load: Any) -> str:
    if isinstance(load, tuple) and all(isinstance(item, (int, float)) for item in load):
        return "(" + ", ".join(f"{item:.2f}" for item in load) + ")"
    return str(load)


def _frame_line(frame: Any, t0: float) -> str:
    """One timeline row: when it landed relative to the probe, and what it was."""
    at = getattr(frame, "at", None)
    when = f"+{at - t0:8.3f}s" if isinstance(at, (int, float)) else "   ?.???s"
    event = str(getattr(frame, "event", "?"))
    data = getattr(frame, "data", None)
    if isinstance(data, dict):
        chunk = data.get("chunk")
        size = len(chunk.encode("utf-8")) if isinstance(chunk, str) else "?"
        detail = f"offset={data.get('offset')} next={data.get('next_offset')} bytes={size}"
        if data.get("eof"):
            detail += f" EOF status={data.get('status')} exit={data.get('exit_code')}"
    else:
        detail = repr(data)[:56]
    return f"  {when}  {event:<8} {detail}"


def _timeline(frames: Sequence[Any], t0: float) -> list[str]:
    if not frames:
        return ["  (no frames arrived at all)"]
    if len(frames) <= _TIMELINE_HEAD + _TIMELINE_TAIL:
        return [_frame_line(frame, t0) for frame in frames]
    elided = len(frames) - _TIMELINE_HEAD - _TIMELINE_TAIL
    return [
        *[_frame_line(frame, t0) for frame in frames[:_TIMELINE_HEAD]],
        f"  ... {elided} frames elided ...",
        *[_frame_line(frame, t0) for frame in frames[-_TIMELINE_TAIL:]],
    ]


def _run_lines(run_id: str | None) -> list[str]:
    """The subprocess's own state: did it exit, with what, having produced what."""
    if run_id is None:
        return []
    run = _safe(lambda: demo_runner._runs.get(run_id))
    if run is None or isinstance(run, str):
        known = _safe(lambda: list(demo_runner._runs))
        return [f"run       : {run_id!r} absent from demo_runner._runs (known: {known})"]
    proc = _safe(lambda: run._process)
    # `returncode` is Popen's cached value -- a plain attribute read. poll()
    # would issue waitpid(2) and could race the monitor thread reaping the
    # child, which is a real behaviour change dressed as a diagnostic.
    process = (
        f"pid={_safe(lambda: proc.pid)} returncode={_safe(lambda: proc.returncode)}"
        if proc is not None and not isinstance(proc, str)
        else f"{proc!r}"
    )
    return [
        f"run       : id={run_id} status={_safe(lambda: run.status)} "
        f"exit_code={_safe(lambda: run.exit_code)} error={_safe(lambda: run.error)!r}",
        f"            log_bytes={_safe(lambda: len(run._log))} "
        f"done={_safe(lambda: run._done.is_set())} "
        f"truncated={_safe(lambda: run._log_truncated)} "
        f"timed_out={_safe(lambda: run._timed_out)}",
        f"            process: {process}",
    ]


class Probe:
    """One test's wall-clock evidence, opened before the window it measures.

    Constructed at the top of a timing-sensitive test. `record()` binds the
    frame list the test is filling -- by reference, so the probe keeps seeing
    frames appended to it after the call, which is what lets a helper that
    raises mid-collection still report what had arrived.
    """

    def __init__(self, what: str, *, run_id: str | None = None) -> None:
        self.what = what
        self.run_id = run_id
        self.start = _sample()
        self.t0 = self.start.at
        self._frames: Sequence[Any] = ()
        self._notes: list[str] = []
        _pending.append(self)

    def bind_run(self, run_id: str) -> Probe:
        self.run_id = run_id
        return self

    def record(self, frames: Sequence[Any]) -> Sequence[Any]:
        """Hold a reference to the live frame list. Returns it, so it can wrap a call."""
        self._frames = frames
        return frames

    def note(self, text: str) -> Probe:
        self._notes.append(text)
        return self

    def elapsed(self) -> float:
        return time.monotonic() - self.t0

    def explain(self, required: str, observed: str = "") -> str:
        """Render the evidence. Only ever called on a failure path."""
        now = _sample()
        frames = list(self._frames)
        events: dict[str, int] = {}
        for frame in frames:
            key = str(getattr(frame, "event", "?"))
            events[key] = events.get(key, 0) + 1
        breakdown = ", ".join(f"{count} {name}" for name, count in sorted(events.items()))

        wall = _delta(now.at, self.t0)
        cpu = _safe(lambda: (now.utime - self.start.utime) + (now.stime - self.start.stime))

        lines = [
            "",
            _HEAVY,
            f"TIMING EVIDENCE -- {self.what}",
            _HEAVY,
            f"required  : {required}",
        ]
        if observed:
            lines.append(f"observed  : {observed}")
        lines += [
            f"elapsed   : {_secs(wall)}s of wall clock since the probe opened",
            _RULE,
            f"frames    : {len(frames)} total"
            + (f" -- {breakdown}" if breakdown else " -- none"),
            *_timeline(frames, self.t0),
            _RULE,
            *_run_lines(self.run_id),
            f"streams   : demo_runner._open_log_streams="
            f"{_safe(lambda: demo_runner._open_log_streams)} "
            f"live_threads={_safe(threading.active_count)}",
            _RULE,
            f"xdist     : worker={worker_id()} of {worker_count()} workers",
            f"host      : cpus={os.cpu_count()} usable={_usable_cpus()}",
            f"loadavg   : at probe start {_loads(self.start.load)} -> now {_loads(now.load)}",
            f"cpu       : {_secs(cpu)}s consumed (self+children) across "
            f"{_secs(wall)}s of wall clock",
            f"switches  : voluntary +{_delta(now.voluntary, self.start.voluntary)}  "
            f"involuntary +{_delta(now.involuntary, self.start.involuntary)}"
            "   (involuntary = preempted by the scheduler)",
        ]
        if self._notes:
            lines += [_RULE, *[f"note      : {note}" for note in self._notes]]
        lines += [
            _RULE,
            # Deliberately does NOT offer "wall >> cpu" as a signal: these
            # scripts sleep by design, so wall dwarfs cpu on a perfectly
            # healthy run too and reading anything into it would be a trap.
            "reading   : STARVED BY LOAD -- load average above the cpu count, a large",
            "            involuntary delta, and frames that all DID arrive, just late",
            "            or bunched. STREAMING BROKEN -- frames missing, or every frame",
            "            landing at the same instant at EOF, while load sits below the",
            "            cpu count and the involuntary delta is small.",
            _HEAVY,
        ]
        return "\n".join(lines)

    def as_record(self) -> dict[str, Any]:
        now = _sample()
        frames = list(self._frames)
        arrivals = [
            _safe(lambda f=frame: round(f.at - self.t0, 4))  # type: ignore[misc]
            for frame in frames
        ]
        return {
            "what": self.what,
            "run_id": self.run_id,
            "worker": worker_id(),
            "worker_count": worker_count(),
            "cpus": os.cpu_count(),
            "wall_seconds": _delta(now.at, self.t0),
            "cpu_seconds": _safe(
                lambda: (now.utime - self.start.utime) + (now.stime - self.start.stime)
            ),
            "involuntary_switches": _delta(now.involuntary, self.start.involuntary),
            "voluntary_switches": _delta(now.voluntary, self.start.voluntary),
            "load_start": self.start.load,
            "load_end": now.load,
            "frame_count": len(frames),
            "frame_arrivals": arrivals[:200],
            "notes": list(self._notes),
        }


def compare_text(left: str, right: str, *, left_name: str, right_name: str) -> str:
    """Where two long texts diverge, as a position and a window around it.

    The unicode burst is ~25KB and the ticking script's log is ~90 bytes; a
    pytest diff of the former is unreadable and hides the one thing worth
    knowing, which is whether the streamed copy is SHORT (delivery stopped
    early -- a timing symptom) or DIFFERENT at some interior offset (the
    decoder or the offset arithmetic is wrong -- not a timing symptom).
    """
    if left == right:
        return "  (the two texts are equal)"
    prefix = 0
    limit = min(len(left), len(right))
    while prefix < limit and left[prefix] == right[prefix]:
        prefix += 1
    lines = [
        f"  {left_name}: {len(left)} chars / {len(left.encode('utf-8'))} bytes",
        f"  {right_name}: {len(right)} chars / {len(right.encode('utf-8'))} bytes",
        f"  common prefix: {prefix} chars"
        + (
            f" -- {left_name} is a strict prefix, i.e. it stopped short"
            if prefix == len(left) < len(right)
            else f" -- {right_name} is a strict prefix"
            if prefix == len(right) < len(left)
            else " -- they diverge mid-text, which is NOT a delivery-stopped-early shape"
        ),
        f"  {left_name} at  {prefix}: {left[prefix : prefix + 60]!r}",
        f"  {right_name} at {prefix}: {right[prefix : prefix + 60]!r}",
    ]
    return "\n".join(lines)


def drain_probes() -> None:
    """Flush and clear the probes a test created. Called from the autouse fixture.

    A no-op unless SSE_TIMING_LOG names a path, so the default run writes
    nothing and the timed paths gain no I/O.
    """
    probes, _pending[:] = list(_pending), []
    target = os.environ.get(_ARTEFACT_ENV)
    if not target or not probes:
        return

    def _write() -> None:
        path = f"{target}.{worker_id()}.jsonl"
        with open(path, "a", encoding="utf-8") as handle:
            for probe in probes:
                handle.write(json.dumps(probe.as_record(), default=str) + "\n")

    _safe(_write)
