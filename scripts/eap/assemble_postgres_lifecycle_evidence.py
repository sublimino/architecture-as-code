#!/usr/bin/env python3
"""SLRC-P2-2 evidence assembler and zero-skip gate.

Combines the pytest junit report, per-test metrics (JSON lines written by the
integration tests when SLRC_LIFECYCLE_METRICS_OUT is set) and the migration
probe into one evidence JSON. Exits non-zero when the run collected nothing,
skipped anything, failed anything, or the migration probe did not pass, so
"no evidence" can never read as "passed". The database password is never
written: the DSN is recorded with its password redacted.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

EXPECTED_METRICS = {
    "concurrent_claims_one_winner",
    "concurrent_claims_throughput",
    "restart_recovery",
    "outbox_two_managers_race",
    "outbox_stale_worker_after_takeover",
    "outbox_rollback_on_insert_failure",
}


def _redact(dsn: str) -> str:
    parts = urlsplit(dsn)
    netloc = parts.netloc
    if parts.password is not None:
        netloc = netloc.replace(f":{parts.password}@", ":***@", 1)
    return urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))


def _git(*args: str) -> str:
    try:
        return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def _junit(path: Path) -> dict:
    if not path.exists():
        return {"present": False, "tests": 0, "passed": 0, "skipped": 0, "failures": 0, "errors": 0, "cases": []}
    root = ET.parse(path).getroot()
    suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
    cases = []
    for suite in suites:
        for case in suite.iter("testcase"):
            outcome = "passed"
            for tag in ("skipped", "failure", "error"):
                node = case.find(tag)
                if node is not None:
                    outcome = tag
                    detail = (node.get("message") or "")[:300]
                    break
            else:
                detail = ""
            cases.append({"name": case.get("name"), "outcome": outcome,
                          "seconds": float(case.get("time") or 0), "detail": detail})
    count = lambda outcome: sum(case["outcome"] == outcome for case in cases)  # noqa: E731
    return {"present": True, "tests": len(cases), "passed": count("passed"), "skipped": count("skipped"),
            "failures": count("failure"), "errors": count("error"), "cases": cases}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--junit", required=True, type=Path)
    parser.add_argument("--metrics", required=True, type=Path)
    parser.add_argument("--migration", required=True, type=Path)
    parser.add_argument("--pytest-log", required=True, type=Path)
    parser.add_argument("--pytest-status", required=True, type=int)
    parser.add_argument("--pytest-args", default="")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    junit = _junit(args.junit)
    metrics: dict[str, list[dict]] = {}
    if args.metrics.exists():
        for line in args.metrics.read_text(encoding="utf-8").splitlines():
            if line.strip():
                record = json.loads(line)
                metrics.setdefault(record.pop("test"), []).append(record)
    migration = json.loads(args.migration.read_text(encoding="utf-8")) if args.migration.exists() else {"ok": False}
    log_tail = args.pytest_log.read_text(encoding="utf-8").splitlines()[-40:] if args.pytest_log.exists() else []

    full_run = args.pytest_args.strip() == ""
    gate = {
        "tests_collected_nonzero": junit["tests"] > 0,
        "zero_skipped": junit["skipped"] == 0,
        "zero_failures": junit["failures"] == 0,
        "zero_errors": junit["errors"] == 0,
        "pytest_exit_zero": args.pytest_status == 0,
        "migration_probe_ok": bool(migration.get("ok")),
        "all_scenarios_reported": EXPECTED_METRICS <= metrics.keys() if full_run else None,
    }
    passed = all(value is not False for value in gate.values())

    evidence = {
        "artifact": "slrc-p2-postgres-evidence",
        "phase": "P2",
        "card": "SLRC-P2-2",
        "generated": datetime.now().astimezone().isoformat(timespec="seconds"),
        "status": "pass" if passed else "fail",
        "gate": gate,
        "repository": {"head": _git("rev-parse", "HEAD"), "worktree_dirty": bool(_git("status", "--porcelain"))},
        "environment": {
            "python": platform.python_version(),
            "database_source": os.environ.get("SLRC_PG_SOURCE", "unknown"),
            "database_image": os.environ.get("SLRC_PG_IMAGE") if os.environ.get("SLRC_PG_CONTAINER") else None,
            "database_container": os.environ.get("SLRC_PG_CONTAINER") or None,
            "database_url_redacted": _redact(os.environ.get("DATABASE_URL", "")),
        },
        "command": "bash scripts/eap/run-postgres-lifecycle-test.sh" + (f" {args.pytest_args}" if args.pytest_args else ""),
        "migration": migration,
        "pytest": {"exit_status": args.pytest_status, **{k: v for k, v in junit.items() if k != "present"},
                   "log_tail": log_tail},
        "scenarios": metrics,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(evidence, indent=2, default=str) + "\n"
    password = urlsplit(os.environ.get("DATABASE_URL", "")).password
    if password:  # belt and braces: a traceback in log_tail may echo the DSN
        text = text.replace(password, "***")
    args.out.write_text(text, encoding="utf-8")
    summary = {k: junit[k] for k in ("tests", "passed", "skipped", "failures", "errors")}
    print(json.dumps({"status": evidence["status"], **summary, "gate": gate}), file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
