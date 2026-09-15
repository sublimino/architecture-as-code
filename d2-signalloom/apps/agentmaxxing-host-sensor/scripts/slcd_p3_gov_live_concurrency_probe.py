#!/usr/bin/env python3
"""SLCD-P3-GOV: A/B/A non-interference probe against the LIVE kanban controller.

Why this exists
---------------
`test_controller_cycle_timing_non_interference` in test_kanban_watcher.py measures a
*mock* controller: `_simulate_controller_cycles()` reads and atomically rewrites JSON
inside a `tempfile.mkdtemp()` tree with `time.sleep(0.001)` per iteration, and the
watcher under test is pointed at that temp tree via KANBAN_HOME. A mock controller
cannot exhibit the lock behaviour the certification exists to prove.

This probe measures the controller that is actually running on this host, using the
controller's OWN cycle-timing counters -- not a stopwatch owned by the probe.

Instrument
----------
  $KANBAN_HOME/telemetry/perf-history.ndjson

One JSON object appended every ~60s by the live controller. Relevant fields:
  capturedAt        epoch ms
  uptimeMs          controller uptime (monotonic within one controller lifetime)
  blockingCount     cumulative count of blocking operations
  loopExcessP99Ms   event-loop excess p99 for the sampling window
  topOperations[]   [{operation, count, totalMs, p99Ms}] -- CUMULATIVE counters

Per-cycle controller cost between two consecutive samples, for operation OP:

    ms_per_cycle(OP) = (totalMs_b - totalMs_a) / (count_b - count_a)

That is the controller's own measurement of its own work, differenced. The probe
never times the controller itself, so the probe's own scheduling cannot bias it.

Experiment
----------
  Phase A  (baseline)  N controller samples, no watcher activity
  Phase B  (load)      N controller samples, watcher+extractor sweeping continuously
  Phase A' (recovery)  N controller samples, no watcher activity

plus a HISTORICAL baseline drawn from every record already in the file at start --
all of which predate this probe entirely.

Null hypothesis
---------------
  H0: the merged Phase 3 watcher+extractor does not increase the live controller's
      per-cycle cost.
  Rejection rule: H0 is REJECTED for a metric if the load-window mean exceeds the
      historical p95 for that metric. p95 (not mean) is the threshold because the
      controller's own cycle cost is noisy across 2000+ historical samples, and a
      load figure inside the historical noise band is by construction not a
      detectable slowdown.

A null result inside the band is a NULL RESULT. It is reported as such and is not
laundered into "the watcher made the controller faster".

Read-only guarantee
-------------------
This probe never writes anywhere under KANBAN_HOME. Its only writes are to --out.
"""
from __future__ import annotations

import argparse
import json
import os
import resource
import statistics
import sys
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PKG_DIR = Path(__file__).resolve().parent.parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

TRACKED_OPS = (
    "sqlite.loadBoard",
    "sqlite.loadSessions",
    "sqlite.updateTaskRunLiveScalars",
    "sqlite.upsertTaskRun",
)

# Minimum delta(count) for a pair to yield a trustworthy per-cycle figure.
MIN_DENOM = 2


class ProbeError(RuntimeError):
    """Raised on any violated assumption. A probe that silently returns a clean
    number is worse than one that errors."""


# ---------------------------------------------------------------------------
# Controller telemetry
# ---------------------------------------------------------------------------

def kanban_home() -> Path:
    return Path(os.environ.get("KANBAN_HOME", str(Path.home() / ".cline" / "kanban")))


def perf_history_path() -> Path:
    return kanban_home() / "telemetry" / "perf-history.ndjson"


def read_records(path: Path) -> List[Dict[str, Any]]:
    """Read every parseable record. Read-only, O_RDONLY, no locks."""
    if not path.exists():
        raise ProbeError(f"controller telemetry absent: {path}")
    out: List[Dict[str, Any]] = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                # trailing partial line during an append; skip, do not fail
                continue
            if isinstance(rec, dict) and "capturedAt" in rec:
                out.append(rec)
    if not out:
        raise ProbeError(f"no parseable records in {path}")
    return out


def op_map(rec: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    ops = rec.get("topOperations") or []
    return {o.get("operation"): o for o in ops if isinstance(o, dict) and o.get("operation")}


def pair_metrics(a: Dict[str, Any], b: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Derive per-cycle metrics from a consecutive record pair.

    Returns None when the pair is not usable:
      - controller restarted between samples (uptimeMs decreased) -> counters reset
      - a cumulative counter went backwards -> counters reset
      - denominators too small to be meaningful
    Excluding these is mandatory: averaging across a counter reset produces a
    negative or absurd per-cycle figure that reads as a spectacular win.
    """
    ua, ub = a.get("uptimeMs"), b.get("uptimeMs")
    if not isinstance(ua, (int, float)) or not isinstance(ub, (int, float)):
        return None
    if ub < ua:
        return None  # controller restarted

    ca, cb = a.get("capturedAt"), b.get("capturedAt")
    if not isinstance(ca, (int, float)) or not isinstance(cb, (int, float)) or cb <= ca:
        return None

    ma, mb = op_map(a), op_map(b)
    metrics: Dict[str, Any] = {
        "from_capturedAt": int(ca),
        "to_capturedAt": int(cb),
        "window_s": round((cb - ca) / 1000.0, 3),
        "loopExcessP99Ms": b.get("loopExcessP99Ms"),
        "ops": {},
    }

    bca, bcb = a.get("blockingCount"), b.get("blockingCount")
    if isinstance(bca, (int, float)) and isinstance(bcb, (int, float)) and bcb >= bca:
        metrics["blockingCountDelta"] = int(bcb - bca)
    else:
        metrics["blockingCountDelta"] = None

    usable_ops = 0
    for op in TRACKED_OPS:
        oa, ob = ma.get(op), mb.get(op)
        if not oa or not ob:
            metrics["ops"][op] = None
            continue
        try:
            dc = int(ob["count"]) - int(oa["count"])
            dt = float(ob["totalMs"]) - float(oa["totalMs"])
        except (KeyError, TypeError, ValueError):
            metrics["ops"][op] = None
            continue
        if dc < 0 or dt < 0:
            return None  # counter reset mid-pair; discard the whole pair
        if dc < MIN_DENOM:
            metrics["ops"][op] = None  # idle window for this op; not an error
            continue
        metrics["ops"][op] = {
            "ms_per_cycle": dt / dc,
            "delta_count": dc,
            "delta_total_ms": round(dt, 3),
            "p99Ms": ob.get("p99Ms"),
        }
        usable_ops += 1

    if usable_ops == 0:
        return None
    return metrics


def derive_series(records: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    out = []
    for a, b in zip(records, records[1:]):
        m = pair_metrics(a, b)
        if m is not None:
            out.append(m)
    return out


def summarise(series: List[Dict[str, Any]]) -> Dict[str, Any]:
    """mean/p50/p95/n per metric. Every figure carries its denominator count."""
    res: Dict[str, Any] = {"pairs": len(series), "ops": {}}
    for op in TRACKED_OPS:
        vals = [s["ops"][op]["ms_per_cycle"] for s in series if s["ops"].get(op)]
        denoms = [s["ops"][op]["delta_count"] for s in series if s["ops"].get(op)]
        if not vals:
            res["ops"][op] = None
            continue
        sv = sorted(vals)
        res["ops"][op] = {
            "n": len(vals),
            "total_cycles_observed": sum(denoms),
            "mean_ms": round(statistics.fmean(vals), 4),
            "p50_ms": round(sv[len(sv) // 2], 4),
            "p95_ms": round(sv[min(len(sv) - 1, int(round(0.95 * (len(sv) - 1))))], 4),
            "min_ms": round(sv[0], 4),
            "max_ms": round(sv[-1], 4),
        }
    lex = [s["loopExcessP99Ms"] for s in series if isinstance(s.get("loopExcessP99Ms"), (int, float))]
    if lex:
        sl = sorted(lex)
        res["loopExcessP99Ms"] = {
            "n": len(sl),
            "mean": round(statistics.fmean(sl), 4),
            "p50": round(sl[len(sl) // 2], 4),
            "p95": round(sl[min(len(sl) - 1, int(round(0.95 * (len(sl) - 1))))], 4),
            "max": round(sl[-1], 4),
        }
    else:
        res["loopExcessP99Ms"] = None
    bcs = [s["blockingCountDelta"] for s in series if isinstance(s.get("blockingCountDelta"), int)]
    res["blockingCountDelta"] = {
        "n": len(bcs),
        "sum": sum(bcs),
        "max": max(bcs) if bcs else None,
    } if bcs else None
    return res


# ---------------------------------------------------------------------------
# Load generator: the merged Phase 3 watcher + extractor against LIVE kanban
# ---------------------------------------------------------------------------

class MergedPhase3Load:
    """Drives BOTH merged Phase 3 surfaces continuously: P3-1's KanbanWatcher and
    P3-2's KanbanCycleExtractor. Certifying one without the other would miss the
    regression where the extractor holds a descriptor open longer than the
    watcher intended."""

    def __init__(self) -> None:
        from kanban_watcher import KanbanWatcher  # noqa: E402
        from kanban import KanbanCycleExtractor  # noqa: E402

        self.watcher = KanbanWatcher()
        self.extractor = KanbanCycleExtractor()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self.sweeps = 0
        self.watcher_ops = 0
        self.extractor_ops = 0
        self.errors: List[str] = []
        self.observed_task_ids: set = set()
        self.emitted_kanban_info: List[Dict[str, Any]] = []

    def _sweep(self) -> None:
        # --- P3-1 watcher surface ---
        tasks = self.watcher.scan_active_tasks()
        self.watcher_ops += 1
        self.watcher.scan_missions()
        self.watcher_ops += 1
        self.watcher.scan_supervisor_cycle_states()
        self.watcher_ops += 1
        for t in tasks:
            self.observed_task_ids.add(getattr(t, "task_id", None))
            if len(self.emitted_kanban_info) < 200:
                try:
                    self.emitted_kanban_info.append(t.to_kanban_info().to_dict())
                except Exception as exc:  # noqa: BLE001
                    self.errors.append(f"to_kanban_info: {type(exc).__name__}: {exc}")

        # --- P3-2 extractor surface ---
        self.extractor.extract_active_sessions()
        self.extractor_ops += 1
        try:
            self.extractor.extract_sessions_from_sqlite()
            self.extractor_ops += 1
        except Exception as exc:  # noqa: BLE001
            self.errors.append(f"extract_sessions_from_sqlite: {type(exc).__name__}: {exc}")
        try:
            self.extractor.extract_cycle_ring("SLCD")
            self.extractor_ops += 1
        except Exception as exc:  # noqa: BLE001
            self.errors.append(f"extract_cycle_ring: {type(exc).__name__}: {exc}")
        try:
            self.extractor.extract_supervisor_state("SLCD")
            self.extractor_ops += 1
        except Exception as exc:  # noqa: BLE001
            self.errors.append(f"extract_supervisor_state: {type(exc).__name__}: {exc}")
        try:
            self.extractor.extract_task_runs_sqlite()
            self.extractor_ops += 1
        except Exception as exc:  # noqa: BLE001
            self.errors.append(f"extract_task_runs_sqlite: {type(exc).__name__}: {exc}")

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self._sweep()
                self.sweeps += 1
            except Exception as exc:  # noqa: BLE001
                self.errors.append(f"sweep: {type(exc).__name__}: {exc}")
                time.sleep(0.05)

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=10.0)


# ---------------------------------------------------------------------------
# Phase runner
# ---------------------------------------------------------------------------

def wait_for_new_records(path: Path, known: int, want: int, timeout_s: float,
                         label: str) -> List[Dict[str, Any]]:
    """Block until `want` NEW records have appeared past index `known`."""
    deadline = time.monotonic() + timeout_s
    while True:
        recs = read_records(path)
        if len(recs) >= known + want:
            return recs
        if time.monotonic() > deadline:
            raise ProbeError(
                f"phase {label}: timed out waiting for {want} new controller samples "
                f"(have {len(recs) - known} after {timeout_s:.0f}s). The controller may "
                f"have stopped. Refusing to emit a verdict from an incomplete window."
            )
        time.sleep(2.0)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--samples", type=int, default=3,
                    help="controller telemetry samples per phase (default 3; ~60s each)")
    ap.add_argument("--timeout-s", type=float, default=0.0,
                    help="per-phase timeout; default = samples*90+120")
    ap.add_argument("--out", default="/tmp/slcd-p3-gov-live-concurrency.json")
    ap.add_argument("--dry-run", action="store_true",
                    help="validate preconditions, print historical baseline, exit")
    ap.add_argument("--freshness-s", type=float, default=180.0)
    args = ap.parse_args()

    per_phase_timeout = args.timeout_s if args.timeout_s > 0 else (args.samples * 90 + 120)

    path = perf_history_path()
    verdict: Dict[str, Any] = {
        "probe": "slcd_p3_gov_live_concurrency_probe",
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kanban_home": str(kanban_home()),
        "instrument": str(path),
        "null_hypothesis": (
            "H0: the merged Phase 3 watcher+extractor does not increase the live "
            "controller's per-cycle cost. REJECT H0 for a metric iff the load-window "
            "mean exceeds the historical p95 for that metric."
        ),
    }

    # --- Precondition 1: instrument exists and the controller is LIVE -------
    records_at_start = read_records(path)
    newest = records_at_start[-1]
    age_s = (time.time() * 1000.0 - float(newest["capturedAt"])) / 1000.0
    verdict["controller_liveness"] = {
        "newest_capturedAt": int(newest["capturedAt"]),
        "newest_age_s": round(age_s, 1),
        "freshness_threshold_s": args.freshness_s,
        "historical_record_count": len(records_at_start),
        "controller_uptime_ms": newest.get("uptimeMs"),
    }
    if age_s > args.freshness_s:
        verdict["verdict"] = "FAIL"
        verdict["error"] = (
            f"no live controller: newest telemetry record is {age_s:.0f}s old "
            f"(threshold {args.freshness_s:.0f}s). A non-interference certification "
            f"against a dead controller is worthless. Refusing to run."
        )
        print(json.dumps(verdict, indent=2))
        return 2

    # --- Historical baseline (predates this probe entirely) -----------------
    hist_series = derive_series(records_at_start)
    verdict["historical_baseline"] = summarise(hist_series)
    verdict["historical_baseline"]["source"] = (
        f"{len(records_at_start)} records already on disk at probe start; every one "
        f"predates this probe and the watcher was not running for any of them"
    )
    verdict["excluded_pairs"] = len(records_at_start) - 1 - len(hist_series)

    if args.dry_run:
        verdict["verdict"] = "DRY-RUN"
        print(json.dumps(verdict, indent=2))
        return 0

    known = len(records_at_start)
    phases: Dict[str, Any] = {}

    # --- Phase A: idle baseline --------------------------------------------
    sys.stderr.write(f"[phase A] idle baseline, waiting for {args.samples} samples...\n")
    sys.stderr.flush()
    recs_a = wait_for_new_records(path, known, args.samples, per_phase_timeout, "A")
    series_a = derive_series(recs_a[known - 1:])
    phases["A_idle_baseline"] = summarise(series_a)
    known_a = len(recs_a)

    # --- Phase B: sustained merged Phase 3 load ----------------------------
    sys.stderr.write(f"[phase B] LOAD: merged watcher+extractor sweeping live kanban...\n")
    sys.stderr.flush()
    ru_before = resource.getrusage(resource.RUSAGE_SELF)
    load = MergedPhase3Load()
    mono_start = time.monotonic()
    load.start()
    try:
        recs_b = wait_for_new_records(path, known_a, args.samples, per_phase_timeout, "B")
    finally:
        load.stop()
    load_wall_s = time.monotonic() - mono_start
    ru_after = resource.getrusage(resource.RUSAGE_SELF)

    series_b = derive_series(recs_b[known_a - 1:])
    phases["B_load"] = summarise(series_b)
    known_b = len(recs_b)

    load_cpu_s = ((ru_after.ru_utime + ru_after.ru_stime)
                  - (ru_before.ru_utime + ru_before.ru_stime))
    verdict["load_generator"] = {
        "sweeps": load.sweeps,
        "watcher_ops": load.watcher_ops,
        "extractor_ops": load.extractor_ops,
        "wall_s": round(load_wall_s, 2),
        "probe_cpu_s": round(load_cpu_s, 3),
        "probe_cpu_pct_of_wall": round((load_cpu_s / load_wall_s) * 100.0, 3) if load_wall_s else None,
        "distinct_live_task_ids_observed": sorted(x for x in load.observed_task_ids if x),
        "emitted_kanban_info_samples": len(load.emitted_kanban_info),
        "errors": load.errors[:20],
        "error_count": len(load.errors),
    }

    # --- Phase A': recovery -------------------------------------------------
    sys.stderr.write(f"[phase A'] recovery, waiting for {args.samples} samples...\n")
    sys.stderr.flush()
    recs_c = wait_for_new_records(path, known_b, args.samples, per_phase_timeout, "A'")
    series_c = derive_series(recs_c[known_b - 1:])
    phases["A2_recovery"] = summarise(series_c)

    verdict["phases"] = phases

    # --- Hypothesis test ----------------------------------------------------
    results: Dict[str, Any] = {}
    overall_pass = True
    any_measured = False
    for op in TRACKED_OPS:
        base = verdict["historical_baseline"]["ops"].get(op)
        loadv = phases["B_load"]["ops"].get(op)
        idlev = phases["A_idle_baseline"]["ops"].get(op)
        if not base or not loadv:
            results[op] = {
                "status": "UNMEASURED",
                "reason": "no usable denominator in one of the windows; not counted as a pass",
            }
            continue
        any_measured = True
        threshold = base["p95_ms"]
        passed = loadv["mean_ms"] <= threshold
        overall_pass = overall_pass and passed
        results[op] = {
            "status": "PASS" if passed else "REJECT-H0",
            "historical_mean_ms": base["mean_ms"],
            "historical_p95_ms": threshold,
            "historical_n": base["n"],
            "idle_window_mean_ms": idlev["mean_ms"] if idlev else None,
            "load_window_mean_ms": loadv["mean_ms"],
            "load_window_cycles_observed": loadv["total_cycles_observed"],
            "delta_vs_historical_mean_pct": round(
                ((loadv["mean_ms"] - base["mean_ms"]) / base["mean_ms"]) * 100.0, 2
            ) if base["mean_ms"] else None,
            "delta_vs_idle_window_pct": round(
                ((loadv["mean_ms"] - idlev["mean_ms"]) / idlev["mean_ms"]) * 100.0, 2
            ) if idlev and idlev["mean_ms"] else None,
            "inside_historical_noise_band": (
                base["min_ms"] <= loadv["mean_ms"] <= base["max_ms"]
            ),
        }

    hb = verdict["historical_baseline"].get("loopExcessP99Ms")
    lb = phases["B_load"].get("loopExcessP99Ms")
    if hb and lb:
        any_measured = True
        passed = lb["mean"] <= hb["p95"]
        overall_pass = overall_pass and passed
        results["loopExcessP99Ms"] = {
            "status": "PASS" if passed else "REJECT-H0",
            "historical_mean": hb["mean"],
            "historical_p95": hb["p95"],
            "idle_window_mean": (phases["A_idle_baseline"].get("loopExcessP99Ms") or {}).get("mean"),
            "load_window_mean": lb["mean"],
            "recovery_window_mean": (phases["A2_recovery"].get("loopExcessP99Ms") or {}).get("mean"),
        }
    else:
        results["loopExcessP99Ms"] = {"status": "UNMEASURED"}

    results["blockingCountDelta"] = {
        "historical": verdict["historical_baseline"].get("blockingCountDelta"),
        "idle": phases["A_idle_baseline"].get("blockingCountDelta"),
        "load": phases["B_load"].get("blockingCountDelta"),
        "recovery": phases["A2_recovery"].get("blockingCountDelta"),
    }

    verdict["hypothesis_test"] = results
    if not any_measured:
        verdict["verdict"] = "INCONCLUSIVE"
        verdict["note"] = (
            "no metric had a usable denominator in both windows. This is not a pass."
        )
    else:
        verdict["verdict"] = "PASS" if overall_pass else "FAIL"

    verdict["interpretation_guard"] = (
        "A load-window figure below the historical mean is a NULL RESULT inside the "
        "controller's own noise band. It is NOT evidence that the watcher made the "
        "controller faster and must not be reported as such."
    )

    Path(args.out).write_text(json.dumps(verdict, indent=2), encoding="utf-8")
    print(json.dumps(verdict, indent=2))
    return 0 if verdict["verdict"] in ("PASS", "DRY-RUN") else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ProbeError as exc:
        sys.stderr.write(f"PROBE ERROR: {exc}\n")
        sys.exit(3)
