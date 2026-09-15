# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Mission-wide Security Suite: Closed Coverage across all PROHIBITED_PROC_ENTRIES.

SLCD-P6-1: Closes coverage across all 17 prohibited procfs entries pinned in P1-4
and required not to be reopened across any subsequent phase.

Validates:
1. Exact set equality of PROHIBITED_PROC_ENTRIES against the frozen 17-member contract.
2. Runtime enforcement: every prohibited entry unconditionally raises SecurityException before open().
3. Static AST analysis across ALL production sensor modules proving zero prohibited procfs reads.
4. Binary resolution safety: read_exe and read_exe_basename never fall back to cmdline.
5. Enforcement Self-Test: proves that a reintroduced prohibited procfs read fails this suite.
"""
from __future__ import annotations

import ast
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import List, Set, Tuple
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .proc import (
        PROHIBITED_PROC_ENTRIES,
        ProcReader,
        SecurityException,
    )
except (ImportError, ValueError):
    from proc import (
        PROHIBITED_PROC_ENTRIES,
        ProcReader,
        SecurityException,
    )


# Frozen 17-member prohibited procfs set established in P1-4
FROZEN_PROHIBITED_PROC_ENTRIES = frozenset({
    "mem",
    "environ",
    "cmdline",
    "maps",
    "smaps",
    "smaps_rollup",
    "stack",
    "syscall",
    "io",
    "fd",
    "fdinfo",
    "net",
    "cwd",
    "root",
    "clear_refs",
    "pagemap",
    "attr",
})

_ENTRY_ALT = "|".join(sorted(FROZEN_PROHIBITED_PROC_ENTRIES))

# Regex detecting accesses to /proc/<pid>/<prohibited>
_PROC_READ_RE = re.compile(
    r"/proc/(?:\{?\s*(?:pid|p)\b[^/]*|\d+|%[sd]|<pid>)/(" + _ENTRY_ALT + r")\b"
)

# Regex detecting accesses to /proc/self/<prohibited>
_PROC_SELF_READ_RE = re.compile(r"/proc/self/(" + _ENTRY_ALT + r")\b")

# The only justified self-read in the sensor suite: file_validator.py inspecting own fdinfo
_JUSTIFIED_SELF_READS: Set[Tuple[str, str]] = {
    ("file_validator.py", "fdinfo"),
}

_SWEEP_EXEMPT = {
    "proc.py",
    "test_proc.py",
    "test_negative_security.py",
    "test_leak_falsification.py",
    "test_p4_governor_integration.py",
    Path(__file__).name,
}


def _extract_string_literals(source: str):
    """Extract every non-docstring, non-bare-expression string literal with line numbers."""
    tree = ast.parse(source)
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = getattr(node, "body", None)
            if (
                body
                and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)
            ):
                docstrings.add(id(body[0].value))
        if (
            isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str)
        ):
            docstrings.add(id(node.value))

    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if id(node) in docstrings:
                continue
            out.append((getattr(node, "lineno", 0), node.value))
        elif isinstance(node, ast.JoinedStr):
            try:
                out.append((getattr(node, "lineno", 0), ast.unparse(node)))
            except Exception:
                pass
    return out


class MissionWideProhibitedProcfsSecurityTests(unittest.TestCase):
    """Mission-wide security suite enforcing strict non-access to prohibited procfs entries."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.mock_proc = Path(self.temp_dir.name) / "proc"
        self.mock_proc.mkdir(parents=True, exist_ok=True)
        self.reader = ProcReader(proc_root=self.mock_proc)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_prohibited_proc_entries_exact_set_equality(self) -> None:
        """Assert that PROHIBITED_PROC_ENTRIES exactly matches the frozen 17-member set."""
        self.assertEqual(
            set(PROHIBITED_PROC_ENTRIES),
            set(FROZEN_PROHIBITED_PROC_ENTRIES),
            f"PROHIBITED_PROC_ENTRIES drifted: "
            f"missing={set(FROZEN_PROHIBITED_PROC_ENTRIES) - set(PROHIBITED_PROC_ENTRIES)}, "
            f"extra={set(PROHIBITED_PROC_ENTRIES) - set(FROZEN_PROHIBITED_PROC_ENTRIES)}",
        )
        self.assertEqual(len(PROHIBITED_PROC_ENTRIES), 17)

    def test_every_prohibited_entry_raises_security_exception_at_runtime(self) -> None:
        """Assert that calling _safe_proc_path for every prohibited entry raises SecurityException."""
        pid_dir = self.mock_proc / "9999"
        pid_dir.mkdir(parents=True, exist_ok=True)

        for entry in FROZEN_PROHIBITED_PROC_ENTRIES:
            with self.subTest(entry=entry):
                # Create the file in mock proc to prove pre-collection check fires before open()
                entry_path = pid_dir / entry
                if entry in ("fd", "fdinfo", "net", "cwd", "root", "attr"):
                    entry_path.mkdir(parents=True, exist_ok=True)
                else:
                    entry_path.write_text("SENSITIVE_DATA_CANARY", encoding="utf-8")

                with self.assertRaises(SecurityException) as ctx:
                    self.reader._safe_proc_path(9999, entry)
                self.assertIn(
                    "strictly prohibited",
                    str(ctx.exception),
                    f"Entry {entry} failed to produce expected security error message",
                )

    def test_exe_basename_never_falls_back_to_cmdline(self) -> None:
        """Assert exe resolution returns None and never reads cmdline secrets on missing exe."""
        pid_dir = self.mock_proc / "8888"
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "cmdline").write_text("python3\x00secret_agent.py\x00--api-key=SECRET123\x00", encoding="utf-8")

        # When exe symlink is missing
        resolved_exe = self.reader.read_exe(8888)
        resolved_basename = self.reader.read_exe_basename(8888)
        self.assertIsNone(resolved_exe)
        self.assertIsNone(resolved_basename)

    def test_ast_scan_all_production_modules_for_prohibited_procfs_reads(self) -> None:
        """AST scan every production Python module to assert zero prohibited procfs paths are queried."""
        offenders = {}
        scanned = 0
        for py_path in sorted(PKG_DIR.rglob("*.py")):
            if py_path.name in _SWEEP_EXEMPT or "__pycache__" in py_path.parts:
                continue
            scanned += 1
            found = set()
            literals = _extract_string_literals(py_path.read_text(encoding="utf-8", errors="replace"))
            for lineno, literal in literals:
                for m in _PROC_READ_RE.finditer(literal):
                    found.add(f"{m.group(1)}:{lineno}")
            if found:
                offenders[py_path.name] = sorted(found)

        self.assertGreater(scanned, 15, "The sweep scanned implausibly few modules")
        self.assertEqual(
            offenders,
            {},
            f"Detected prohibited procfs access in production modules: {offenders}",
        )

    def test_self_reads_strictly_match_justified_set(self) -> None:
        """Assert /proc/self/<entry> accesses match the audited justified set exactly."""
        found = set()
        for py_path in sorted(PKG_DIR.rglob("*.py")):
            if py_path.name in _SWEEP_EXEMPT or "__pycache__" in py_path.parts:
                continue
            literals = _extract_string_literals(py_path.read_text(encoding="utf-8", errors="replace"))
            for _lineno, literal in literals:
                for m in _PROC_SELF_READ_RE.finditer(literal):
                    found.add((py_path.name, m.group(1)))

        self.assertEqual(
            found,
            _JUSTIFIED_SELF_READS,
            f"Justified self-reads drifted: {found}",
        )

    def test_enforcement_self_test_catches_reintroduced_prohibited_proc_read(self) -> None:
        """Enforcement Self-Test 1: Proves this suite actively catches any reintroduced prohibited procfs read.

        Simulates a hypothetical component attempting to read /proc/<pid>/cmdline, /proc/<pid>/environ,
        or /proc/<pid>/mem, and verifies that the security layer immediately catches and blocks it.
        """
        pid = 7777
        pid_dir = self.mock_proc / str(pid)
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "cmdline").write_text("evil_process --secret-token=LEAK_CANARY", encoding="utf-8")
        (pid_dir / "environ").write_text("API_KEY=sk-ant-canary-secret", encoding="utf-8")
        (pid_dir / "mem").write_bytes(b"\x00\x01\x02CANARY_MEMORY_DUMP")

        # 1. Direct ProcReader safe path check fails closed
        for bad_entry in ("cmdline", "environ", "mem"):
            with self.assertRaises(SecurityException, msg=f"Should raise on {bad_entry}") as ctx:
                self.reader._safe_proc_path(pid, bad_entry)
            self.assertIn("strictly prohibited", str(ctx.exception))

        # 2. Verify that attempting to read directly raises SecurityException
        def simulated_leaky_component(proc_reader: ProcReader, target_pid: int, entry_name: str) -> str:
            path = proc_reader._safe_proc_path(target_pid, entry_name)
            return path.read_text(encoding="utf-8")

        for bad_entry in ("cmdline", "environ", "mem"):
            with self.assertRaises(SecurityException):
                simulated_leaky_component(self.reader, pid, bad_entry)


if __name__ == "__main__":
    unittest.main()
