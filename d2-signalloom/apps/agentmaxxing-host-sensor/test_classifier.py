"""Comprehensive test suite for HarnessAncestryClassifier.

Verifies:
1. Multi-signal corroboration and anti-spoofing resilience (renamed binary, prctl PR_SET_NAME, cross-harness mimic).
2. True-positive accuracy for Claude Code, Antigravity, OpenAI Codex, CPAI, OpenCode, Hermes, Aider.
3. Multi-hop ancestry tree traversal and depth attenuation.
4. Process tree race safety (PID recycling, orphan reparenting, cycle guards, mid-walk exits).
5. Zero false-positive rate across ordinary developer tools (compilers, IDEs, shells, runtimes).
6. Zero-Customer-Payload invariant (zero cmdline reads, zero PROHIBITED_PROC_ENTRIES accesses).
7. Schema conformance with codingagent.v1 frozen contract.
"""
from __future__ import annotations

import ast
from pathlib import Path
import sys
import tempfile
from typing import Dict, List, Optional
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .classifier import (
        HARNESS_SIGNATURES,
        ClassificationClaim,
        HarnessAncestryClassifier,
        HarnessSignature,
        NullProtocolCorroborator,
        ProtocolCorroborator,
        SessionMarkerCorroborator,
    )
    from .coding_agent_models import CodingAgentTelemetry, Harness, KanbanInfo, MetricsInfo, NetworkInfo, ProcessInfo, ToolCounts
    from .collector import ProcessTelemetryCollector, ScannedProcess
    from .models import BoundedProcessAttributes, HealthState
    from .proc import PROHIBITED_PROC_ENTRIES, ProcReader, ProcStat
except (ImportError, ValueError):
    from classifier import (
        HARNESS_SIGNATURES,
        ClassificationClaim,
        HarnessAncestryClassifier,
        HarnessSignature,
        NullProtocolCorroborator,
        ProtocolCorroborator,
        SessionMarkerCorroborator,
    )
    from coding_agent_models import CodingAgentTelemetry, Harness, KanbanInfo, MetricsInfo, NetworkInfo, ProcessInfo, ToolCounts
    from collector import ProcessTelemetryCollector, ScannedProcess
    from models import BoundedProcessAttributes, HealthState
    from proc import PROHIBITED_PROC_ENTRIES, ProcReader, ProcStat


class MockProtocolCorroborator:
    """Mock socket protocol corroborator for testing P4-2 socket integration."""

    def __init__(self, verdicts: Optional[Dict[int, bool]] = None) -> None:
        self.verdicts: Dict[int, bool] = verdicts or {}

    def corroborate_socket(self, pid: int, harness: Harness) -> Optional[bool]:
        return self.verdicts.get(pid)


class HarnessAncestryClassifierTests(unittest.TestCase):
    """Exhaustive test suite for harness process ancestry classifier."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.mock_proc = Path(self.temp_dir.name) / "proc"
        self.mock_home = Path(self.temp_dir.name) / "home"
        self.mock_proc.mkdir(parents=True, exist_ok=True)
        self.mock_home.mkdir(parents=True, exist_ok=True)

        self.proc_reader = ProcReader(proc_root=self.mock_proc, page_size=4096, clk_tck=100)
        self.session_corroborator = SessionMarkerCorroborator(home_dir=self.mock_home)
        self.classifier = HarnessAncestryClassifier(
            proc_reader=self.proc_reader,
            session_corroborator=self.session_corroborator,
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _setup_mock_process(
        self,
        pid: int,
        comm: str,
        ppid: int = 1,
        state: str = "R",
        starttime_ticks: int = 100000,
        exe_target: Optional[str] = None,
        rss_pages: int = 1024,
    ) -> Path:
        pid_dir = self.mock_proc / str(pid)
        pid_dir.mkdir(parents=True, exist_ok=True)
        stat_line = (
            f"{pid} ({comm}) {state} {ppid} 1 1 0 0 4194304 0 0 0 0 "
            f"100 50 0 0 20 0 1 0 {starttime_ticks} 5000000 {rss_pages} "
            f"0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
        )
        (pid_dir / "stat").write_text(stat_line, encoding="utf-8")
        (pid_dir / "statm").write_text(f"2000 {rss_pages} 500 100 0 100 0\n", encoding="utf-8")
        (pid_dir / "status").write_text(f"Name:\t{comm}\nState:\t{state}\nPPid:\t{ppid}\n", encoding="utf-8")
        if exe_target:
            exe_link = pid_dir / "exe"
            if exe_link.is_symlink() or exe_link.exists():
                exe_link.unlink()
            exe_link.symlink_to(exe_target)
        return pid_dir

    def _make_scanned_process(
        self,
        pid: int,
        comm: str,
        ppid: int = 1,
        exe_basename: Optional[str] = None,
        starttime_ticks: int = 100000,
    ) -> ScannedProcess:
        stat = ProcStat(
            pid=pid,
            comm=comm,
            state="R",
            ppid=ppid,
            pgrp=1,
            session=1,
            utime_ticks=100,
            stime_ticks=50,
            cutime_ticks=0,
            cstime_ticks=0,
            starttime_ticks=starttime_ticks,
            vsize_bytes=5000000,
            rss_pages=1024,
            exit_code_raw=None,
        )
        attrs = BoundedProcessAttributes(
            health_state=HealthState.RUNNING,
            cpu_time_ms=1500,
            resident_memory_bytes=4194304,
            pid=pid,
            ppid=ppid,
        )
        return ScannedProcess(
            pid=pid,
            ppid=ppid,
            comm=comm,
            exe_basename=exe_basename,
            stat=stat,
            attributes=attrs,
            starttime_ticks=starttime_ticks,
        )

    # -------------------------------------------------------------------------
    # 1. Anti-Spoofing & Resilience Tests
    # -------------------------------------------------------------------------

    def test_spoof_renamed_binary_mimicking_claude(self) -> None:
        """A renamed binary (/usr/bin/sleep renamed to 'claude') must NOT be attributed to Claude."""
        self._setup_mock_process(
            pid=2001,
            comm="claude",
            ppid=1,
            exe_target="/usr/bin/sleep",
        )
        claim = self.classifier.classify_process(2001)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)
        self.assertIn("comm_mismatch_exe_rejected", claim.corroboration_signals)
        self.assertEqual(claim.to_telemetry_harness(), Harness.UNKNOWN)

    def test_spoof_prctl_set_name_mimicking_agy(self) -> None:
        """A Python script that calls prctl(PR_SET_NAME, 'agy') must NOT be attributed to Antigravity."""
        self._setup_mock_process(
            pid=2002,
            comm="agy",
            ppid=1,
            exe_target="/usr/bin/python3.11",
        )
        claim = self.classifier.classify_process(2002)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)
        self.assertIn("comm_mismatch_exe_rejected", claim.corroboration_signals)
        self.assertEqual(claim.to_telemetry_harness(), Harness.UNKNOWN)

    def test_spoof_prctl_set_name_mimicking_cpai(self) -> None:
        """A compiler process setting comm to 'cpai-launcher' must be rejected as unknown."""
        self._setup_mock_process(
            pid=2003,
            comm="cpai-launcher",
            ppid=1,
            exe_target="/usr/bin/gcc",
        )
        claim = self.classifier.classify_process(2003)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)
        self.assertIn("comm_mismatch_exe_rejected", claim.corroboration_signals)

    def test_spoof_cross_harness_mimic(self) -> None:
        """A Claude binary claiming to be 'agy' in comm must NOT be attributed to Antigravity."""
        self._setup_mock_process(
            pid=2004,
            comm="agy",
            ppid=1,
            exe_target="/usr/local/bin/claude",
        )
        claim = self.classifier.classify_process(2004)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)
        self.assertIn("comm_mismatch_exe_rejected", claim.corroboration_signals)

    def test_spoof_fake_parent_in_ancestry_tree(self) -> None:
        """A child compiler whose parent claims 'claude' via comm but is /bin/bash must be unknown."""
        # Parent PID 3000: comm='claude', exe='/bin/bash' (spoofed parent)
        self._setup_mock_process(
            pid=3000,
            comm="claude",
            ppid=1,
            starttime_ticks=10000,
            exe_target="/bin/bash",
        )
        # Child PID 3001: comm='gcc', ppid=3000
        self._setup_mock_process(
            pid=3001,
            comm="gcc",
            ppid=3000,
            starttime_ticks=10500,
            exe_target="/usr/bin/gcc",
        )
        claim = self.classifier.classify_process(3001)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)

    def test_benign_node_process_not_codex(self) -> None:
        """A standard Node.js server (comm='node', exe='/usr/bin/node') must classify as UNKNOWN."""
        self._setup_mock_process(
            pid=4001,
            comm="node",
            ppid=1,
            exe_target="/usr/bin/node",
        )
        claim = self.classifier.classify_process(4001)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)
        self.assertIn("insufficient_secondary_corroboration", claim.corroboration_signals)

    def test_benign_python_process_not_aider(self) -> None:
        """A standard Python utility (comm='python3', exe='/usr/bin/python3') must classify as UNKNOWN."""
        self._setup_mock_process(
            pid=4002,
            comm="python3",
            ppid=1,
            exe_target="/usr/bin/python3.11",
        )
        claim = self.classifier.classify_process(4002)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)

    # -------------------------------------------------------------------------
    # 2. True-Positive Tests for Real Signatures (P2-PRE Database)
    # -------------------------------------------------------------------------

    def test_true_positive_claude_code(self) -> None:
        """Claude Code matching real installed path and comm must classify with 1.0 confidence."""
        self._setup_mock_process(
            pid=1001,
            comm="claude",
            ppid=1,
            exe_target="/home/andy/.local/share/claude/versions/2.1.220/claude",
        )
        claim = self.classifier.classify_process(1001)
        self.assertEqual(claim.harness, Harness.CLAUDE)
        self.assertEqual(claim.confidence, 1.0)
        self.assertEqual(claim.harness_pid, 1001)
        self.assertEqual(claim.ancestry_depth, 0)
        self.assertIn("comm_match", claim.corroboration_signals)
        self.assertIn("exe_provenance_verified", claim.corroboration_signals)
        self.assertEqual(claim.to_telemetry_harness(), Harness.CLAUDE)

    def test_true_positive_antigravity(self) -> None:
        """Antigravity CLI (comm='agy', exe='~/.local/bin/agy') must classify as ANTIGRAVITY."""
        self._setup_mock_process(
            pid=1002,
            comm="agy",
            ppid=1,
            exe_target="/home/andy/.local/bin/agy",
        )
        claim = self.classifier.classify_process(1002)
        self.assertEqual(claim.harness, Harness.ANTIGRAVITY)
        self.assertEqual(claim.confidence, 1.0)
        self.assertEqual(claim.harness_pid, 1002)
        self.assertEqual(claim.ancestry_depth, 0)
        self.assertEqual(claim.to_telemetry_harness(), Harness.ANTIGRAVITY)

    def test_true_positive_codex_with_session_marker(self) -> None:
        """Codex CLI running node with active session store must classify as CODEX."""
        # Create mock session marker
        (self.mock_home / ".codex" / "sessions").mkdir(parents=True, exist_ok=True)
        # Binary provenance must be process-specific. A real Codex CLI install resolves
        # /proc/<pid>/exe into its own package tree, not into the bare system node binary;
        # SLCD-P2-GOV corrected this fixture after confirming the real install layout.
        self._setup_mock_process(
            pid=1003,
            comm="node",
            ppid=1,
            exe_target="/home/dev/.local/lib/node_modules/@openai/codex/bin/codex.js",
        )
        claim = self.classifier.classify_process(1003)
        self.assertEqual(claim.harness, Harness.CODEX)
        self.assertGreaterEqual(claim.confidence, 0.90)
        self.assertEqual(claim.harness_pid, 1003)
        self.assertIn("session_marker_verified", claim.corroboration_signals)

    def test_true_positive_cpai_swarm(self) -> None:
        """CPAI launcher (comm='cpai-launcher', exe='.../cpai-launcher') must classify as CPAI."""
        self._setup_mock_process(
            pid=1004,
            comm="cpai-launcher",
            ppid=1,
            exe_target="/home/andy/src/cp/cpai-cli/cmd/cpai/cpai-launcher",
        )
        claim = self.classifier.classify_process(1004)
        self.assertEqual(claim.harness, Harness.CPAI)
        self.assertEqual(claim.confidence, 1.0)
        self.assertEqual(claim.harness_pid, 1004)

    def test_true_positive_opencode(self) -> None:
        """OpenCode (comm='opencode', exe='.../opencode') must classify as OPENCODE."""
        self._setup_mock_process(
            pid=1005,
            comm="opencode",
            ppid=1,
            exe_target="/home/andy/.opencode/bin/opencode",
        )
        claim = self.classifier.classify_process(1005)
        self.assertEqual(claim.harness, Harness.OPENCODE)
        self.assertEqual(claim.confidence, 1.0)

    def test_true_positive_hermes_coordinator(self) -> None:
        """Hermes coordinator (comm='hermes') must classify as HERMES."""
        self._setup_mock_process(
            pid=1006,
            comm="hermes",
            ppid=1,
            exe_target="/home/andy/.local/bin/hermes",
        )
        claim = self.classifier.classify_process(1006)
        self.assertEqual(claim.harness, Harness.HERMES)
        self.assertEqual(claim.confidence, 1.0)

    def test_true_positive_aider(self) -> None:
        """Aider CLI (comm='aider', exe='.../aider') must classify as AIDER."""
        self._setup_mock_process(
            pid=1007,
            comm="aider",
            ppid=1,
            exe_target="/home/andy/.local/bin/aider",
        )
        claim = self.classifier.classify_process(1007)
        self.assertEqual(claim.harness, Harness.AIDER)
        self.assertGreaterEqual(claim.confidence, 0.90)

    # -------------------------------------------------------------------------
    # 3. Multi-Hop Ancestry Tree Walking Tests
    # -------------------------------------------------------------------------

    def test_multihop_single_hop_compiler(self) -> None:
        """Single-hop: Claude (100) -> gcc (101). Compiler must be attributed to Claude."""
        self._setup_mock_process(
            pid=100,
            comm="claude",
            ppid=1,
            starttime_ticks=10000,
            exe_target="/home/andy/.local/share/claude/versions/2.1.220/claude",
        )
        self._setup_mock_process(
            pid=101,
            comm="gcc",
            ppid=100,
            starttime_ticks=10100,
            exe_target="/usr/bin/gcc",
        )
        claim = self.classifier.classify_process(101)
        self.assertEqual(claim.harness, Harness.CLAUDE)
        self.assertEqual(claim.confidence, 0.98)  # 1.0 - (1 * 0.02)
        self.assertEqual(claim.harness_pid, 100)
        self.assertEqual(claim.ancestry_depth, 1)
        self.assertIn("process_tree_ancestry", claim.corroboration_signals)

    def test_multihop_two_hop_antigravity(self) -> None:
        """Two-hop: Agy (100) -> bash (101) -> make (102)."""
        self._setup_mock_process(
            pid=100,
            comm="agy",
            ppid=1,
            starttime_ticks=10000,
            exe_target="/home/andy/.local/bin/agy",
        )
        self._setup_mock_process(
            pid=101,
            comm="bash",
            ppid=100,
            starttime_ticks=10100,
            exe_target="/bin/bash",
        )
        self._setup_mock_process(
            pid=102,
            comm="make",
            ppid=101,
            starttime_ticks=10200,
            exe_target="/usr/bin/make",
        )
        claim = self.classifier.classify_process(102)
        self.assertEqual(claim.harness, Harness.ANTIGRAVITY)
        self.assertEqual(claim.confidence, 0.96)  # 1.0 - (2 * 0.02)
        self.assertEqual(claim.harness_pid, 100)
        self.assertEqual(claim.ancestry_depth, 2)

    def test_multihop_three_hop_cpai(self) -> None:
        """Three-hop: CPAI (100) -> sh (101) -> cargo (102) -> rustc (103)."""
        self._setup_mock_process(
            pid=100,
            comm="cpai-launcher",
            ppid=1,
            starttime_ticks=10000,
            exe_target="/home/andy/src/cp/cpai-cli/cmd/cpai/cpai-launcher",
        )
        self._setup_mock_process(
            pid=101,
            comm="sh",
            ppid=100,
            starttime_ticks=10100,
            exe_target="/bin/dash",
        )
        self._setup_mock_process(
            pid=102,
            comm="cargo",
            ppid=101,
            starttime_ticks=10200,
            exe_target="/usr/bin/cargo",
        )
        self._setup_mock_process(
            pid=103,
            comm="rustc",
            ppid=102,
            starttime_ticks=10300,
            exe_target="/usr/bin/rustc",
        )
        claim = self.classifier.classify_process(103)
        self.assertEqual(claim.harness, Harness.CPAI)
        self.assertEqual(claim.confidence, 0.94)  # 1.0 - (3 * 0.02)
        self.assertEqual(claim.harness_pid, 100)
        self.assertEqual(claim.ancestry_depth, 3)

    def test_multihop_four_hop_assembler(self) -> None:
        """Four-hop: Codex (100) -> bash (101) -> make (102) -> gcc (103) -> as (104)."""
        (self.mock_home / ".codex" / "sessions").mkdir(parents=True, exist_ok=True)
        self._setup_mock_process(
            pid=100,
            comm="node",
            ppid=1,
            starttime_ticks=10000,
            exe_target="/home/dev/.local/lib/node_modules/@openai/codex/bin/codex.js",
        )
        self._setup_mock_process(
            pid=101,
            comm="bash",
            ppid=100,
            starttime_ticks=10100,
            exe_target="/bin/bash",
        )
        self._setup_mock_process(
            pid=102,
            comm="make",
            ppid=101,
            starttime_ticks=10200,
            exe_target="/usr/bin/make",
        )
        self._setup_mock_process(
            pid=103,
            comm="gcc",
            ppid=102,
            starttime_ticks=10300,
            exe_target="/usr/bin/gcc",
        )
        self._setup_mock_process(
            pid=104,
            comm="as",
            ppid=103,
            starttime_ticks=10400,
            exe_target="/usr/bin/as",
        )
        claim = self.classifier.classify_process(104)
        self.assertEqual(claim.harness, Harness.CODEX)
        self.assertGreaterEqual(claim.confidence, 0.85)
        self.assertEqual(claim.harness_pid, 100)
        self.assertEqual(claim.ancestry_depth, 4)

    def test_multihop_depth_bound_protection(self) -> None:
        """Ancestry walk bounded to max_depth=5 stops safely without runaway recursion."""
        classifier_small_depth = HarnessAncestryClassifier(
            proc_reader=self.proc_reader,
            session_corroborator=self.session_corroborator,
            max_ancestry_depth=4,
        )
        # Chain of 6 hops before reaching claude
        # 100 (claude) <- 101 <- 102 <- 103 <- 104 <- 105 (target)
        self._setup_mock_process(pid=100, comm="claude", ppid=1, starttime_ticks=1000, exe_target="/usr/local/bin/claude")
        self._setup_mock_process(pid=101, comm="sh", ppid=100, starttime_ticks=1010, exe_target="/bin/sh")
        self._setup_mock_process(pid=102, comm="sh", ppid=101, starttime_ticks=1020, exe_target="/bin/sh")
        self._setup_mock_process(pid=103, comm="sh", ppid=102, starttime_ticks=1030, exe_target="/bin/sh")
        self._setup_mock_process(pid=104, comm="sh", ppid=103, starttime_ticks=1040, exe_target="/bin/sh")
        self._setup_mock_process(pid=105, comm="gcc", ppid=104, starttime_ticks=1050, exe_target="/usr/bin/gcc")

        claim = classifier_small_depth.classify_process(105)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)

    # -------------------------------------------------------------------------
    # 4. Race Safety & Process Tree Edge Cases
    # -------------------------------------------------------------------------

    def test_race_pid_reuse_newer_parent(self) -> None:
        """When parent PID is recycled to a newer process (parent starttime > child starttime), reject."""
        # Child 200 spawned at starttime 10000
        # Parent PID was 150. But parent PID 150 is now a new process started at starttime 12000!
        self._setup_mock_process(
            pid=150,
            comm="claude",
            ppid=1,
            starttime_ticks=12000,  # Newer than child!
            exe_target="/home/andy/.local/share/claude/versions/2.1.220/claude",
        )
        self._setup_mock_process(
            pid=200,
            comm="gcc",
            ppid=150,
            starttime_ticks=10000,  # Older than parent!
            exe_target="/usr/bin/gcc",
        )
        claim = self.classifier.classify_process(200)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)
        self.assertIn("pid_reuse_race_detected", claim.corroboration_signals)

    def test_race_orphan_reparented_to_init(self) -> None:
        """When parent exits and orphan child is reparented to init (PID 1), return UNKNOWN."""
        self._setup_mock_process(
            pid=300,
            comm="gcc",
            ppid=1,  # Reparented to systemd
            starttime_ticks=10000,
            exe_target="/usr/bin/gcc",
        )
        claim = self.classifier.classify_process(300)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)

    def test_race_missing_parent_mid_walk(self) -> None:
        """When parent process vanishes mid-walk (not in procfs), handle cleanly as UNKNOWN."""
        self._setup_mock_process(
            pid=400,
            comm="gcc",
            ppid=9999,  # Parent does not exist
            starttime_ticks=10000,
            exe_target="/usr/bin/gcc",
        )
        claim = self.classifier.classify_process(400)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)

    def test_race_cyclic_process_table(self) -> None:
        """A corrupted cyclic process table (PID 50 -> PPID 51 -> PPID 50) must not hang."""
        self._setup_mock_process(
            pid=50,
            comm="wrapper1",
            ppid=51,
            starttime_ticks=10000,
            exe_target="/bin/sh",
        )
        self._setup_mock_process(
            pid=51,
            comm="wrapper2",
            ppid=50,  # Cycle!
            starttime_ticks=10000,
            exe_target="/bin/sh",
        )
        claim = self.classifier.classify_process(50)
        self.assertEqual(claim.harness, Harness.UNKNOWN)
        self.assertEqual(claim.confidence, 0.0)

    # -------------------------------------------------------------------------
    # 5. False-Positive Rate Stress Benchmark (Target: 0% False Positives)
    # -------------------------------------------------------------------------

    def test_zero_false_positive_stress_benchmark(self) -> None:
        """Measure false-positive rate across 45 ordinary developer tools and daemons."""
        ordinary_tools = [
            # Compilers and linkers
            ("gcc", "/usr/bin/gcc"),
            ("g++", "/usr/bin/g++"),
            ("clang", "/usr/bin/clang"),
            ("clang++", "/usr/bin/clang++"),
            ("rustc", "/usr/bin/rustc"),
            ("cargo", "/usr/bin/cargo"),
            ("go", "/usr/bin/go"),
            ("javac", "/usr/bin/javac"),
            ("kotlinc", "/usr/bin/kotlinc"),
            ("ld", "/usr/bin/ld"),
            ("lld", "/usr/bin/lld"),
            ("as", "/usr/bin/as"),
            ("nasm", "/usr/bin/nasm"),
            # Build systems
            ("make", "/usr/bin/make"),
            ("ninja", "/usr/bin/ninja"),
            ("cmake", "/usr/bin/cmake"),
            ("bazel", "/usr/bin/bazel"),
            ("mvn", "/usr/bin/mvn"),
            ("gradle", "/usr/bin/gradle"),
            # Shells and terminal utilities
            ("bash", "/bin/bash"),
            ("zsh", "/usr/bin/zsh"),
            ("sh", "/bin/dash"),
            ("fish", "/usr/bin/fish"),
            ("tmux", "/usr/bin/tmux"),
            ("screen", "/usr/bin/screen"),
            # Version control
            ("git", "/usr/bin/git"),
            ("hg", "/usr/bin/hg"),
            ("svn", "/usr/bin/svn"),
            # IDEs and editors
            ("code", "/usr/share/code/code"),
            ("idea", "/opt/idea-IU-241.17011.79/bin/idea.sh"),
            ("vim", "/usr/bin/vim"),
            ("nvim", "/usr/bin/nvim"),
            ("emacs", "/usr/bin/emacs"),
            ("nano", "/usr/bin/nano"),
            # System daemons and network tools
            ("systemd", "/usr/lib/systemd/systemd"),
            ("sshd", "/usr/sbin/sshd"),
            ("dbus-daemon", "/usr/bin/dbus-daemon"),
            ("cron", "/usr/sbin/cron"),
            ("curl", "/usr/bin/curl"),
            ("wget", "/usr/bin/wget"),
            ("grep", "/usr/bin/grep"),
            ("find", "/usr/bin/find"),
            ("docker", "/usr/bin/docker"),
            ("dockerd", "/usr/bin/dockerd"),
            ("kubectl", "/usr/bin/kubectl"),
        ]

        scanned_list: List[ScannedProcess] = []
        for i, (comm, exe_path) in enumerate(ordinary_tools, start=5000):
            sp = self._make_scanned_process(
                pid=i,
                comm=comm,
                ppid=1,
                exe_basename=Path(exe_path).name,
                starttime_ticks=100000 + i,
            )
            scanned_list.append(sp)

        # Batch classification
        claims = self.classifier.classify_batch(scanned_list)

        false_positives = 0
        for sp in scanned_list:
            claim = claims[sp.pid]
            if claim.harness != Harness.UNKNOWN or claim.confidence > 0.0:
                false_positives += 1

        total_tested = len(scanned_list)
        fp_rate = (false_positives / total_tested) * 100.0

        # Assert 0 false positives KPI
        self.assertEqual(
            false_positives,
            0,
            f"False positives detected: {false_positives}/{total_tested} ({fp_rate:.2f}%)",
        )
        self.assertEqual(fp_rate, 0.0)

    # -------------------------------------------------------------------------
    # 6. Protocol Corroborator & Stub Verification
    # -------------------------------------------------------------------------

    def test_null_protocol_corroborator_returns_none(self) -> None:
        """NullProtocolCorroborator must return None and not falsely claim corroboration."""
        null_proto = NullProtocolCorroborator()
        self.assertIsNone(null_proto.corroborate_socket(1234, Harness.CLAUDE))
        self.assertIsNone(null_proto.corroborate_socket(1234, Harness.ANTIGRAVITY))
        self.assertIsNone(null_proto.corroborate_socket(1234, Harness.CODEX))

    def test_protocol_corroborator_integration(self) -> None:
        """When socket protocol corroborator returns True, Codex classification succeeds."""
        mock_proto = MockProtocolCorroborator(verdicts={5001: True})
        proto_classifier = HarnessAncestryClassifier(
            proc_reader=self.proc_reader,
            protocol_corroborator=mock_proto,
            session_corroborator=self.session_corroborator,
        )
        self._setup_mock_process(
            pid=5001,
            comm="node",
            ppid=1,
            exe_target="/usr/bin/node",
        )
        claim = proto_classifier.classify_process(5001)
        self.assertEqual(claim.harness, Harness.CODEX)
        self.assertGreaterEqual(claim.confidence, 0.90)
        self.assertIn("socket_protocol_verified", claim.corroboration_signals)

    # -------------------------------------------------------------------------
    # 7. Static & Runtime Security Invariants
    # -------------------------------------------------------------------------

    def test_static_guard_no_cmdline_in_classifier(self) -> None:
        """Assert classifier.py contains zero occurrences of 'cmdline' string literal."""
        classifier_src = (PKG_DIR / "classifier.py").read_text(encoding="utf-8")
        parsed_ast = ast.parse(classifier_src)

        for node in ast.walk(parsed_ast):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                self.assertNotIn(
                    "cmdline",
                    node.value.lower(),
                    f"Forbidden string literal containing 'cmdline' found in classifier.py: {node.value!r}",
                )

    def test_runtime_assertion_zero_prohibited_proc_entries(self) -> None:
        """Assert classifier execution accesses zero PROHIBITED_PROC_ENTRIES."""
        accessed_entries: List[str] = []
        original_safe_path = self.proc_reader._safe_proc_path

        def intercept_safe_path(pid: int, entry_name: str) -> Path:
            accessed_entries.append(entry_name)
            return original_safe_path(pid, entry_name)

        self.proc_reader._safe_proc_path = intercept_safe_path  # type: ignore

        # Run process classification on Claude tree
        self._setup_mock_process(pid=6000, comm="claude", ppid=1, exe_target="/usr/local/bin/claude")
        self._setup_mock_process(pid=6001, comm="gcc", ppid=6000, exe_target="/usr/bin/gcc")

        claim = self.classifier.classify_process(6001)
        self.assertEqual(claim.harness, Harness.CLAUDE)

        # Assert no prohibited entries were accessed
        for prohibited in PROHIBITED_PROC_ENTRIES:
            self.assertNotIn(
                prohibited,
                accessed_entries,
                f"Prohibited procfs entry '{prohibited}' was accessed during classification!",
            )

    # -------------------------------------------------------------------------
    # 8. Schema & Telemetry Conformance
    # -------------------------------------------------------------------------

    def test_coding_agent_telemetry_schema_conformance(self) -> None:
        """Assert classified claims convert cleanly to CodingAgentTelemetry conforming to schema."""
        self._setup_mock_process(pid=7000, comm="agy", ppid=1, exe_target="/usr/local/bin/agy")
        claim = self.classifier.classify_process(7000)

        harness_enum = claim.to_telemetry_harness()
        self.assertEqual(harness_enum, Harness.ANTIGRAVITY)

        telemetry = CodingAgentTelemetry(
            harness=harness_enum,
            session_id="a" * 64,
            timestamp="2026-09-15T05:00:00Z",
            process=ProcessInfo(
                pid=7000,
                ppid=1,
                comm="agy",
                rss_bytes=104857600,
                cpu_ticks=450,
            ),
            kanban=KanbanInfo(
                task_id="SLCD-P2-2",
                shortcode="SLCD",
                role="implementation",
                elapsed_s=120,
            ),
            metrics=MetricsInfo(
                step_count=14,
                tokens_in=125000,
                tokens_out=4200,
                tool_counts=ToolCounts(view_file=8, run_command=3),
            ),
            network=NetworkInfo(
                inference_endpoint="api.anthropic.com",
                egress_bytes=45000,
            ),
        )

        telemetry.validate()
        data = telemetry.to_dict()
        self.assertEqual(data["harness"], "antigravity")
        self.assertEqual(data["process"]["comm"], "agy")


if __name__ == "__main__":
    unittest.main()
