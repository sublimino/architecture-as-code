"""SLCD-P3-GOV: cross-card integration guards for merged Phase 3.

These tests exist because every P3-1 and P3-2 test fixture was hand-written, and
the shapes they hand-wrote are not the shapes the live kanban controller emits.
A suite can be 242-green and still have never seen a real record.

New file by design: P3-1 owns test_kanban_watcher.py and P3-2 owns test_kanban.py,
and the shared-file collision rules for this phase say a card keeps to its own
block. Governor findings land here.
"""
from __future__ import annotations

import json
import os
import resource
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

from coding_agent_models import coerce_turn_count  # noqa: E402
from kanban import KanbanCycleExtractor  # noqa: E402
from kanban_watcher import KanbanWatcher  # noqa: E402

LIVE_KANBAN = Path(os.environ.get("KANBAN_HOME", str(Path.home() / ".cline" / "kanban")))

# The exact shape the LIVE controller writes. Captured from
# ~/.cline/kanban/workspaces/osramp-demo/sessions.json on 2026-09-15.
# Every P3-1/P3-2 fixture instead writes `"latestTurnCheckpoint": 1`.
LIVE_SESSION_SHAPE = {
    "taskId": "10898",
    "state": "awaiting_review",
    "pid": 4242,
    "startedAt": 1788384907310,
    "updatedAt": 1788384999000,
    "latestTurnCheckpoint": {
        "turn": 7,
        "ref": "refs/kanban/checkpoints/MTA4OTg/turn/1",
        "commit": "b49636cfd20945a0a7447b0f753b992d9c01d066",
        "createdAt": 1788384907310,
    },
    "restartCount": 1,
    "respawnCount": 0,
}


class TurnCheckpointShapeTests(unittest.TestCase):
    """The object-vs-integer divergence that took out the whole sessions path."""

    def test_live_object_shape_yields_the_inner_turn(self) -> None:
        self.assertEqual(coerce_turn_count(LIVE_SESSION_SHAPE["latestTurnCheckpoint"]), 7)

    def test_legacy_integer_shape_still_works(self) -> None:
        """The fix must widen the accepted set, not move it."""
        self.assertEqual(coerce_turn_count(5), 5)
        self.assertEqual(coerce_turn_count(0), 0)
        self.assertEqual(coerce_turn_count(None), 0)

    def test_coercion_never_stringifies_the_checkpoint_object(self) -> None:
        """Zero-Customer-Payload: `ref` and `commit` are free-text-shaped git
        identifiers. A coercion that fell through to str(raw) would turn a shape
        bug into a payload leak, and would still return a plausible integer for
        most callers, so nothing downstream would notice."""
        obj = dict(LIVE_SESSION_SHAPE["latestTurnCheckpoint"])
        out = coerce_turn_count(obj)
        self.assertIsInstance(out, int)
        rendered = repr(out)
        self.assertNotIn("refs/kanban", rendered)
        self.assertNotIn("b49636cf", rendered)

    def test_hostile_shapes_degrade_to_zero_not_exception(self) -> None:
        for bad in ({"turn": {"nested": 1}}, {"turn": "abc"}, {"nope": 1}, [], "", True,
                    {"turn": True}, float("nan"), float("inf")):
            with self.subTest(bad=bad):
                self.assertEqual(coerce_turn_count(bad), 0)

    def test_extractor_survives_the_live_shape(self) -> None:
        """Regression for the TypeError that took out extract_active_sessions and
        extract_sessions_from_sqlite against 100% of real sessions."""
        e = KanbanCycleExtractor()
        obs = e.extract_from_session_dict(session_data=dict(LIVE_SESSION_SHAPE),
                                          workspace_id="osramp-demo")
        self.assertEqual(obs.turn_count, 7)

    def test_watcher_reports_the_real_turn_not_a_fabricated_zero(self) -> None:
        """P3-1 caught the TypeError and returned 0. A fabricated zero is worse
        than a crash because it reads as data."""
        tmp = Path(tempfile.mkdtemp(prefix="p3gov-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        ws = tmp / "workspaces" / "osramp-demo"
        ws.mkdir(parents=True)
        (tmp / "auto-controller").mkdir()
        (ws / "sessions.json").write_text(
            json.dumps({"10898": dict(LIVE_SESSION_SHAPE)}), encoding="utf-8")
        with patch.dict(os.environ, {"KANBAN_HOME": str(tmp)}):
            tasks = KanbanWatcher().scan_active_tasks()
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0].turn_count, 7,
                         "watcher fabricated a zero turn count from the live shape")


class MergedSchemaConformanceTests(unittest.TestCase):
    """P1-1's frozen allowlist, re-run against MERGED Phase 3 output rather than
    spot-checked against a few emitted records."""

    FROZEN = {"task_id", "shortcode", "role", "elapsed_s"}

    @unittest.skipUnless(LIVE_KANBAN.is_dir(), "no live kanban home")
    def test_every_emitted_record_matches_the_frozen_allowlist_exactly(self) -> None:
        w = KanbanWatcher()
        tasks = w.scan_active_tasks()
        self.assertGreater(len(tasks), 0, "no live tasks: conformance claim would be vacuous")
        for t in tasks:
            d = t.to_kanban_info().to_dict()
            # set equality, not subset: a subset check passes on a record that
            # dropped a required field.
            self.assertEqual(set(d), self.FROZEN, f"field drift on {d}")
            self.assertIsInstance(d["elapsed_s"], int)

    @unittest.skipUnless(LIVE_KANBAN.is_dir(), "no live kanban home")
    def test_merged_extractor_output_matches_the_frozen_allowlist_exactly(self) -> None:
        e = KanbanCycleExtractor()
        obs = e.extract_active_sessions()
        self.assertGreater(len(obs), 0)
        for o in obs:
            self.assertEqual(set(o.to_kanban_info().to_dict()), self.FROZEN)


class CleanDisableOnMergedTreeTests(unittest.TestCase):
    """Re-verified through the MERGED pair. P3-2's extractor must not assume the
    watcher returned a non-None result."""

    def test_watcher_and_extractor_both_degrade_on_a_host_without_kanban(self) -> None:
        tmp = Path(tempfile.mkdtemp(prefix="p3gov-absent-"))
        shutil.rmtree(tmp, ignore_errors=True)  # guarantee it does not exist
        with patch.dict(os.environ, {"KANBAN_HOME": str(tmp)}):
            w = KanbanWatcher()
            self.assertFalse(w.is_available)
            self.assertEqual(w.scan_active_tasks(), [])
            self.assertEqual(w.scan_missions(), [])
            self.assertEqual(w.scan_supervisor_cycle_states(), {})

            e = KanbanCycleExtractor()
            self.assertEqual(e.extract_active_sessions(), [])
            self.assertEqual(e.extract_sessions_from_sqlite(), [])
            self.assertEqual(e.extract_task_runs_sqlite(), [])
            self.assertEqual(e.extract_cycle_ring("SLCD"), [])
            self.assertEqual(e.extract_supervisor_state("SLCD"), [])

    def test_extractor_does_not_assume_watcher_returned_something(self) -> None:
        """The regression P3-2's extraction logic could have introduced."""
        tmp = Path(tempfile.mkdtemp(prefix="p3gov-empty-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "workspaces").mkdir(parents=True)
        (tmp / "auto-controller").mkdir()
        with patch.dict(os.environ, {"KANBAN_HOME": str(tmp)}):
            w = KanbanWatcher()
            self.assertEqual(w.scan_active_tasks(), [])
            e = KanbanCycleExtractor()
            self.assertEqual(e.extract_active_sessions(), [])


class ReadOnlyPostureScopeTests(unittest.TestCase):
    """Pins WHERE the merged Phase 3 path is allowed to lock or write.

    SLCD-P3-GOV measured the merged path under strace against the live controller
    and found it is NOT lock-free and NOT write-free: `sqlite3.connect(
    "file:...?mode=ro")` at kanban.py:533 opens `kanban.sqlite-wal` and
    `kanban.sqlite-shm` with O_RDWR|O_CREAT and takes POSIX record locks on them,
    including F_WRLCK on the WAL-index recovery byte. `mode=ro` constrains the
    MAIN database only; it does not make a WAL connection passive.

    The grep-based guard (`rg 'open\\(.*"w'`) is structurally blind to this because
    the opens are issued by libsqlite3, not by a Python `open()`.

    This test asserts the invariant that IS true and that must stay true: the JSON
    surface is strictly O_RDONLY and lock-free, and every lock or write-capable
    open is confined to `kanban.sqlite*`. It therefore survives a future fix to the
    SQLite path and still catches a NEW violation introduced anywhere else.
    """

    TRACE = "flock,fcntl,openat,write,pwrite64,renameat,renameat2,unlinkat,ftruncate"

    def _trace(self, body: str) -> str:
        if not shutil.which("strace"):
            self.skipTest("strace unavailable; posture cannot be decided at syscall layer")
        src = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
        src.write(f"import sys; sys.path.insert(0, {str(PKG_DIR)!r})\n{body}")
        src.close()
        self.addCleanup(os.unlink, src.name)
        out = tempfile.NamedTemporaryFile("w", suffix=".strace", delete=False)
        out.close()
        self.addCleanup(os.unlink, out.name)
        subprocess.run(["strace", "-f", "-qq", "-y", "-e", f"trace={self.TRACE}",
                        "-o", out.name, sys.executable, src.name],
                       capture_output=True, text=True, timeout=180)
        return Path(out.name).read_text(errors="replace")

    @unittest.skipUnless(LIVE_KANBAN.is_dir(), "no live kanban home")
    def test_json_surface_is_strictly_readonly_and_lock_free(self) -> None:
        trace = self._trace(
            "from kanban_watcher import KanbanWatcher\n"
            "w = KanbanWatcher()\n"
            "w.scan_active_tasks(); w.scan_missions(); w.scan_supervisor_cycle_states()\n"
        )
        home = str(LIVE_KANBAN)
        offenders = [
            ln for ln in trace.splitlines()
            if home in ln and (
                "flock(" in ln
                or "l_type=" in ln
                or any(f in ln for f in ("O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "O_APPEND"))
            )
        ]
        self.assertEqual(offenders, [],
                         f"P3-1 JSON surface is no longer lock/write free: {offenders[:3]}")
        touched = [ln for ln in trace.splitlines() if home in ln and "openat" in ln]
        self.assertGreater(len(touched), 0,
                           "workload never read the kanban tree; a clean result proves nothing")

    @unittest.skipUnless(LIVE_KANBAN.is_dir(), "no live kanban home")
    def test_all_lock_and_write_activity_is_confined_to_sqlite_files(self) -> None:
        trace = self._trace(
            "from kanban import KanbanCycleExtractor\n"
            "e = KanbanCycleExtractor()\n"
            "e.extract_active_sessions(); e.extract_sessions_from_sqlite()\n"
            "e.extract_task_runs_sqlite(); e.extract_cycle_ring('SLCD')\n"
            "e.extract_supervisor_state('SLCD')\n"
        )
        home = str(LIVE_KANBAN)
        escapes = []
        for ln in trace.splitlines():
            if home not in ln:
                continue
            is_lock_or_write = (
                "flock(" in ln or "l_type=" in ln
                or any(f in ln for f in ("O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "O_APPEND"))
            )
            if is_lock_or_write and "kanban.sqlite" not in ln:
                escapes.append(ln.strip()[:200])
        self.assertEqual(escapes, [],
                         "lock/write activity escaped the kanban.sqlite* scope: "
                         f"{escapes[:3]}")


class CombinedP2P3OverheadTests(unittest.TestCase):
    """P2's process-tree engine and P3's kanban watcher in ONE process.

    P2-GOV set the KPI and measured P2 alone; P3-1 measured P3 alone. Neither
    number covers the shipped configuration, which is both engines inside the same
    sensor process. These thresholds are read from P2's own test source rather
    than restated, so they cannot drift apart silently.
    """

    CPU_BUDGET_PERCENT = 1.0        # test_p2_governor_integration.py:604
    RSS_BUDGET_BYTES = 25 * 1024 * 1024  # test_p2_governor_integration.py:605

    def test_p2_thresholds_still_match_p2s_own_source(self) -> None:
        """If P2 moves its KPI, this file must not keep certifying against a stale copy."""
        src = (PKG_DIR / "test_p2_governor_integration.py").read_text(encoding="utf-8")
        self.assertIn("CPU_BUDGET_PERCENT = 1.0", src)
        self.assertIn("RSS_BUDGET_BYTES = 25 * 1024 * 1024", src)

    @staticmethod
    def _cpu_seconds() -> float:
        ru = resource.getrusage(resource.RUSAGE_SELF)
        return ru.ru_utime + ru.ru_stime

    @unittest.skipUnless(LIVE_KANBAN.is_dir(), "no live kanban home")
    def test_combined_engines_within_cpu_and_rss_budget(self) -> None:
        from collector import CodingAgentCollector  # noqa: E402

        watcher = KanbanWatcher()
        collector = CodingAgentCollector(kanban_watcher=watcher)
        extractor = KanbanCycleExtractor()

        # warm both engines so import/compile cost is not charged to the measurement
        collector.classify_scanned_processes(collector.scan_processes(max_pids=40))
        watcher.scan_active_tasks()
        extractor.extract_active_sessions()

        cpu_before = self._cpu_seconds()
        wall_before = time.monotonic()
        for _ in range(10):
            # --- P2 surface ---
            collector.classify_scanned_processes(collector.scan_processes(max_pids=100))
            # --- P3 surface ---
            watcher.scan_active_tasks()
            watcher.scan_missions()
            extractor.extract_active_sessions()
            extractor.extract_sessions_from_sqlite()
        wall = time.monotonic() - wall_before
        cpu = self._cpu_seconds() - cpu_before
        peak_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024

        # Model the shipped duty cycle: one combined sweep per 0.5s poll.
        duty_pct = (cpu / (10 * 0.5)) * 100.0
        print(f"\n[BENCHMARK] Combined P2+P3, 10 sweeps: wall={wall*1000:.1f}ms "
              f"cpu={cpu*1000:.1f}ms duty_cycle_cpu={duty_pct:.3f}% "
              f"peak_rss={peak_rss/1048576:.2f}MB "
              f"(KPI: <{self.CPU_BUDGET_PERCENT}% CPU, <{self.RSS_BUDGET_BYTES/1048576:.0f}MB RSS)")

        self.assertLess(duty_pct, self.CPU_BUDGET_PERCENT,
                        f"combined duty-cycle CPU {duty_pct:.3f}% exceeds "
                        f"{self.CPU_BUDGET_PERCENT}% KPI")
        # RSS is asserted here. P3-1's own overhead test printed peak RSS and
        # asserted only on CPU, so the 45.77 MB it reported was never a gate.
        self.assertLess(peak_rss, self.RSS_BUDGET_BYTES,
                        f"combined peak RSS {peak_rss/1048576:.2f} MB exceeds "
                        f"{self.RSS_BUDGET_BYTES/1048576:.0f} MB KPI")


if __name__ == "__main__":
    unittest.main()
