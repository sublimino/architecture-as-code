#!/usr/bin/env python3
"""SLCD-P3-GOV: syscall-level proof that merged Phase 3 acquires no locks and writes nothing.

Why this exists
---------------
`test_lock_contention_immunity` (test_kanban_watcher.py) holds an exclusive `flock`
on `$KANBAN_HOME/kanban-mutation.lock` and asserts the watcher does not block. But
`KanbanWatcher` never opens that path -- it reads `workspaces/*/sessions.json` and
`auto-controller/*.json`. The assertion is true of the wrong file: a watcher that
acquired `LOCK_EX` on `sessions.json` passes that test unchanged.

"Non-interfering read lock" is a claim about file locking, and file locking on Linux
is exactly three mechanisms:
    1. flock(2)
    2. fcntl(2) POSIX record locks   (F_SETLK / F_SETLKW / F_OFD_SETLK / F_OFD_SETLKW)
    3. open(2) mode-induced exclusion (O_WRONLY / O_RDWR / O_CREAT / O_TRUNC / O_APPEND)
So the claim is decidable at the syscall layer and nowhere else. This probe decides it.

Falsifiability
--------------
A probe that only ever returns "clean" is indistinguishable from a probe that is not
looking. `--positive-control` runs a deliberately GUILTY workload through the exact
same tracer and parser; the parser MUST convict it. The probe's own PASS is only
meaningful because its FAIL has been demonstrated.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

PKG_DIR = Path(__file__).resolve().parent.parent

WRITE_FLAGS = ("O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "O_APPEND")
LOCKING_FCNTL_CMDS = ("F_SETLK", "F_SETLKW", "F_OFD_SETLK", "F_OFD_SETLKW")
WRITE_SYSCALLS = ("write", "pwrite64", "pwritev", "writev", "renameat", "renameat2",
                  "unlinkat", "ftruncate", "fallocate", "mkdirat", "linkat", "symlinkat")

TRACED = ",".join((
    "flock", "fcntl", "openat", "openat2", "open",
    *WRITE_SYSCALLS,
))

# strace lines look like:  [pid 123] openat(AT_FDCWD, "/path", O_RDONLY|O_CLOEXEC) = 3
OPENAT_RE = re.compile(r'open(?:at2?)?\(([^)]*)"((?:[^"\\]|\\.)*)"[^)]*?(?:,\s*([A-Z_|0-9]+))?\)\s*=\s*(-?\d+)')
FD_RE = re.compile(r'\)\s*=\s*(\d+)')


# ---------------------------------------------------------------------------
# Workloads
# ---------------------------------------------------------------------------

INNOCENT_WORKLOAD = r'''
import sys, time
sys.path.insert(0, {pkg!r})
from kanban_watcher import KanbanWatcher
from kanban import KanbanCycleExtractor
w = KanbanWatcher()
e = KanbanCycleExtractor()
deadline = time.monotonic() + {secs}
n = 0
while time.monotonic() < deadline:
    w.scan_active_tasks()
    w.scan_missions()
    w.scan_supervisor_cycle_states()
    e.extract_active_sessions()
    e.extract_sessions_from_sqlite()
    e.extract_task_runs_sqlite()
    e.extract_cycle_ring("SLCD")
    e.extract_supervisor_state("SLCD")
    n += 1
sys.stderr.write("SWEEPS=%d\n" % n)
'''

# Deliberately guilty: takes an exclusive flock, a POSIX record lock, and writes,
# all against paths under the SAME kanban home the innocent workload reads. If the
# parser does not convict this, the parser is not looking.
GUILTY_WORKLOAD = r'''
import fcntl, os, sys, time
home = {home!r}
target = os.path.join(home, "slcd-p3-gov-positive-control.tmp")
f = open(target, "w")            # O_WRONLY|O_CREAT|O_TRUNC
fcntl.flock(f.fileno(), fcntl.LOCK_EX)
f.write("positive control\n")
f.flush()
fcntl.lockf(f.fileno(), fcntl.F_LOCK, 0, 0)   # fcntl F_SETLKW
fcntl.lockf(f.fileno(), fcntl.F_ULOCK, 0, 0)
fcntl.flock(f.fileno(), fcntl.LOCK_UN)
f.close()
os.unlink(target)
sys.stderr.write("GUILTY_DONE\n")
'''


def run_traced(code: str, trace_path: Path, timeout_s: float) -> Dict[str, Any]:
    src = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
    src.write(code)
    src.close()
    cmd = [
        "strace", "-f", "-qq", "-y",
        "-e", f"trace={TRACED}",
        "-o", str(trace_path),
        sys.executable, src.name,
    ]
    t0 = time.monotonic()
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)
    os.unlink(src.name)
    return {
        "argv": cmd[:6] + ["<tmp>.py"],
        "returncode": proc.returncode,
        "wall_s": round(time.monotonic() - t0, 2),
        "stderr_tail": proc.stderr.strip().splitlines()[-4:],
        "trace_lines": sum(1 for _ in open(trace_path, "r", errors="replace")),
    }


def analyse(trace_path: Path, guard_substr: str) -> Dict[str, Any]:
    """Convict or acquit based on the trace. `guard_substr` scopes path-sensitive
    findings to the kanban tree so unrelated process activity (python importing
    its own stdlib, writing to stderr) cannot produce a false conviction."""
    findings: Dict[str, Any] = {
        "flock_calls": [],
        "fcntl_lock_calls": [],
        "write_mode_opens_in_scope": [],
        "write_syscalls_in_scope": [],
        "readonly_opens_in_scope": 0,
        "opens_in_scope_total": 0,
        "all_in_scope_open_flagsets": {},
    }

    for raw in open(trace_path, "r", errors="replace"):
        line = raw.rstrip("\n")

        if "flock(" in line and "ENOSYS" not in line:
            findings["flock_calls"].append(line.strip()[:240])

        if "fcntl(" in line and any(c in line for c in LOCKING_FCNTL_CMDS):
            findings["fcntl_lock_calls"].append(line.strip()[:240])

        m = OPENAT_RE.search(line)
        if m:
            path = m.group(2)
            flags = m.group(3) or ""
            if guard_substr in path:
                findings["opens_in_scope_total"] += 1
                key = flags or "(none)"
                findings["all_in_scope_open_flagsets"][key] = \
                    findings["all_in_scope_open_flagsets"].get(key, 0) + 1
                if any(wf in flags for wf in WRITE_FLAGS):
                    findings["write_mode_opens_in_scope"].append(line.strip()[:240])
                elif "O_RDONLY" in flags or flags == "":
                    findings["readonly_opens_in_scope"] += 1

        for sc in WRITE_SYSCALLS:
            # -y makes strace annotate fds as <path>, so an in-scope write is visible
            if line.lstrip().startswith(sc + "(") or f"] {sc}(" in line:
                if guard_substr in line:
                    findings["write_syscalls_in_scope"].append(line.strip()[:240])
                break

    guilty = bool(
        findings["flock_calls"]
        or findings["fcntl_lock_calls"]
        or findings["write_mode_opens_in_scope"]
        or findings["write_syscalls_in_scope"]
    )
    findings["verdict"] = "GUILTY" if guilty else "CLEAN"
    # keep the report readable
    for k in ("flock_calls", "fcntl_lock_calls", "write_mode_opens_in_scope",
              "write_syscalls_in_scope"):
        findings[k + "_count"] = len(findings[k])
        findings[k] = findings[k][:5]
    return findings


def census(root: Path) -> Dict[str, Any]:
    """mtime+size census of the kanban tree, so a write that slipped past the
    tracer would still show up as a changed file."""
    entries = {}
    for dirpath, dirnames, filenames in os.walk(root):
        # the controller itself is mutating sqlite/wal/telemetry continuously;
        # those are excluded because the controller, not the watcher, writes them.
        for fn in filenames:
            p = Path(dirpath) / fn
            try:
                st = p.stat()
            except OSError:
                continue
            entries[str(p)] = (st.st_size, int(st.st_mtime_ns))
    return entries


def lslocks_for(pid: Optional[int]) -> Dict[str, Any]:
    exe = shutil.which("lslocks")
    if not exe:
        return {"available": False}
    try:
        out = subprocess.run([exe, "-n", "-o", "PID,TYPE,MODE,PATH"],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception as exc:  # noqa: BLE001
        return {"available": True, "error": str(exc)}
    rows = [l.strip() for l in out.splitlines() if l.strip()]
    mine = [r for r in rows if pid is not None and r.split()[0:1] == [str(pid)]]
    kanban_rows = [r for r in rows if ".cline/kanban" in r]
    return {
        "available": True,
        "total_locks_on_host": len(rows),
        "locks_held_by_probe_pid": mine,
        "locks_anywhere_under_kanban_home": kanban_rows[:10],
        "locks_anywhere_under_kanban_home_count": len(kanban_rows),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=6.0,
                    help="duration of the traced sweep loop")
    ap.add_argument("--out", default="/tmp/slcd-p3-gov-lock-syscall.json")
    ap.add_argument("--keep-traces", action="store_true")
    args = ap.parse_args()

    home = Path(os.environ.get("KANBAN_HOME", str(Path.home() / ".cline" / "kanban")))
    guard = ".cline/kanban" if ".cline/kanban" in str(home) else str(home)

    report: Dict[str, Any] = {
        "probe": "slcd_p3_gov_lock_syscall_probe",
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kanban_home": str(home),
        "scope_substring": guard,
        "traced_syscalls": TRACED.split(","),
        "claim_decomposition": {
            "flock": "zero flock(2) calls",
            "fcntl_record_locks": f"zero fcntl(2) with any of {LOCKING_FCNTL_CMDS}",
            "open_mode": f"zero in-scope open with any of {WRITE_FLAGS}",
            "write_syscalls": "zero write-class syscalls against an in-scope path",
        },
    }

    if not shutil.which("strace"):
        report["verdict"] = "UNMEASURED"
        report["error"] = ("strace not available; the lock claim cannot be decided at the "
                           "syscall layer on this host. Source inspection is NOT a "
                           "substitute and must not be reported as one.")
        print(json.dumps(report, indent=2))
        return 4

    tmpdir = Path(tempfile.mkdtemp(prefix="slcd-p3-gov-strace-"))
    innocent_trace = tmpdir / "innocent.strace"
    guilty_trace = tmpdir / "guilty.strace"

    # ---- census before ----
    before = census(home)

    # ---- the real workload ----
    code = INNOCENT_WORKLOAD.format(pkg=str(PKG_DIR), secs=args.seconds)
    try:
        run_meta = run_traced(code, innocent_trace, timeout_s=args.seconds + 180)
    except subprocess.TimeoutExpired:
        report["verdict"] = "UNMEASURED"
        report["error"] = "traced workload timed out"
        print(json.dumps(report, indent=2))
        return 5
    report["merged_phase3_workload"] = run_meta
    report["merged_phase3_findings"] = analyse(innocent_trace, guard)

    # ---- lslocks while nothing of ours holds anything ----
    report["lslocks"] = lslocks_for(None)

    # ---- census after ----
    after = census(home)
    changed = {k: {"before": before[k], "after": after[k]}
               for k in set(before) & set(after) if before[k] != after[k]}
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    report["kanban_tree_census"] = {
        "files_before": len(before),
        "files_after": len(after),
        "changed_count": len(changed),
        "added": added[:20],
        "removed": removed[:20],
        "changed_sample": dict(list(changed.items())[:10]),
        "note": ("The live controller mutates kanban.sqlite*, telemetry/* and "
                 "auto-controller/* continuously during the window. Those changes are "
                 "the CONTROLLER's writes, not the watcher's; the syscall trace is the "
                 "authority on who wrote what, and the census is corroboration only."),
    }

    # ---- POSITIVE CONTROL: prove the parser can convict ----
    gcode = GUILTY_WORKLOAD.format(home=str(home))
    try:
        greg = run_traced(gcode, guilty_trace, timeout_s=120)
        gfind = analyse(guilty_trace, guard)
    except subprocess.TimeoutExpired:
        greg, gfind = {"error": "timeout"}, {"verdict": "UNMEASURED"}
    report["positive_control"] = {
        "purpose": ("runs a workload that DOES flock, DOES take a POSIX record lock and "
                    "DOES write, through the identical tracer and parser. The parser must "
                    "return GUILTY. If it returns CLEAN the probe is blind and its PASS on "
                    "the real workload is worthless."),
        "run": greg,
        "findings": gfind,
    }

    # ---- verdict ----
    real_clean = report["merged_phase3_findings"]["verdict"] == "CLEAN"
    control_convicted = gfind.get("verdict") == "GUILTY"
    exercised = report["merged_phase3_findings"]["opens_in_scope_total"] > 0

    checks = {
        "merged_phase3_acquired_no_locks_and_wrote_nothing": real_clean,
        "probe_demonstrated_able_to_fail": control_convicted,
        "workload_actually_touched_the_kanban_tree": exercised,
    }
    report["checks"] = checks
    report["verdict"] = "PASS" if all(checks.values()) else "FAIL"
    if not exercised:
        report["failure_reason"] = ("zero in-scope opens: the workload never read the "
                                    "kanban tree, so a CLEAN result proves nothing")
    if not control_convicted:
        report["failure_reason"] = ("positive control was not convicted: the parser is "
                                    "blind, so CLEAN on the real workload is not evidence")

    if args.keep_traces:
        report["trace_files"] = {"innocent": str(innocent_trace), "guilty": str(guilty_trace)}
    else:
        shutil.rmtree(tmpdir, ignore_errors=True)

    Path(args.out).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
