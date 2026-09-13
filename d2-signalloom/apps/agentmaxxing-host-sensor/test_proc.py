"""Unit tests for /proc filesystem reader."""
from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
from typing import Optional
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .proc import (
        ProcReader,
        ProcStat,
        ProcStatm,
        ProcStatus,
        SecurityException,
    )
except (ImportError, ValueError):
    from proc import (
        ProcReader,
        ProcStat,
        ProcStatm,
        ProcStatus,
        SecurityException,
    )


class ProcReaderTests(unittest.TestCase):
    """Test suite for safe /proc metric extraction."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.mock_proc = Path(self.temp_dir.name)
        self.reader = ProcReader(
            proc_root=self.mock_proc,
            page_size=4096,
            clk_tck=100,
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _create_mock_pid(
        self,
        pid: int,
        stat_line: str,
        statm_line: Optional[str] = None,
        status_lines: Optional[str] = None,
    ) -> Path:
        pid_dir = self.mock_proc / str(pid)
        pid_dir.mkdir(parents=True, exist_ok=True)
        (pid_dir / "stat").write_text(stat_line, encoding="utf-8")
        if statm_line:
            (pid_dir / "statm").write_text(statm_line, encoding="utf-8")
        if status_lines:
            (pid_dir / "status").write_text(status_lines, encoding="utf-8")
        return pid_dir

    def test_read_stat_standard_process(self) -> None:
        stat_line = (
            "1234 (agent-worker) S 1000 1234 1234 0 0 4194304 100 0 0 0 "
            "150 50 0 0 20 0 4 0 500000 10485760 2000 18446744073709551615 "
            "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
        )
        self._create_mock_pid(1234, stat_line)

        stat = self.reader.read_stat(1234)
        self.assertIsNotNone(stat)
        assert stat is not None
        self.assertEqual(stat.pid, 1234)
        self.assertEqual(stat.comm, "agent-worker")
        self.assertEqual(stat.state, "S")
        self.assertEqual(stat.ppid, 1000)
        self.assertEqual(stat.utime_ticks, 150)
        self.assertEqual(stat.stime_ticks, 50)
        self.assertEqual(stat.rss_pages, 2000)

        # 150 + 50 = 200 ticks at 100 Hz = 2000 ms
        self.assertEqual(self.reader.cpu_time_ms(stat), 2000)
        # 2000 pages * 4096 bytes = 8192000 bytes
        self.assertEqual(self.reader.rss_bytes(stat), 8192000)

    def test_read_stat_comm_with_spaces_and_nested_parens(self) -> None:
        stat_line = (
            "4567 (worker (pool) thread 1) R 1000 4567 4567 0 0 4194304 0 0 0 0 "
            "300 100 0 0 20 0 1 0 100000 5000000 1000 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
        )
        self._create_mock_pid(4567, stat_line)

        stat = self.reader.read_stat(4567)
        self.assertIsNotNone(stat)
        assert stat is not None
        self.assertEqual(stat.pid, 4567)
        self.assertEqual(stat.comm, "worker (pool) thread 1")
        self.assertEqual(stat.state, "R")
        self.assertEqual(stat.utime_ticks, 300)
        self.assertEqual(stat.stime_ticks, 100)
        self.assertEqual(self.reader.cpu_time_ms(stat), 4000)

    def test_read_statm(self) -> None:
        self._create_mock_pid(
            1234,
            "1234 (agent) S 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
            statm_line="5000 2500 1000 100 0 500 0",
        )

        statm = self.reader.read_statm(1234)
        self.assertIsNotNone(statm)
        assert statm is not None
        self.assertEqual(statm.size_pages, 5000)
        self.assertEqual(statm.resident_pages, 2500)
        self.assertEqual(statm.shared_pages, 1000)

    def test_read_status(self) -> None:
        status_text = (
            "Name:\tagentmaxxing\n"
            "State:\tS (sleeping)\n"
            "Tgid:\t9999\n"
            "Pid:\t9999\n"
            "PPid:\t42\n"
            "VmSize:\t  102400 kB\n"
            "VmRSS:\t   32768 kB\n"
            "Threads:\t8\n"
        )
        self._create_mock_pid(9999, "9999 (agent) S 42 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0", status_lines=status_text)

        status = self.reader.read_status(9999)
        self.assertIsNotNone(status)
        assert status is not None
        self.assertEqual(status.name, "agentmaxxing")
        self.assertEqual(status.state, "S")
        self.assertEqual(status.ppid, 42)
        self.assertEqual(status.vm_rss_bytes, 32768 * 1024)
        self.assertEqual(status.vm_size_bytes, 102400 * 1024)
        self.assertEqual(status.threads, 8)

    def test_nonexistent_pid_returns_none(self) -> None:
        self.assertIsNone(self.reader.read_stat(999999))
        self.assertIsNone(self.reader.read_statm(999999))
        self.assertIsNone(self.reader.read_status(999999))
        self.assertFalse(self.reader.is_pid_alive(999999))

    def test_security_violation_on_prohibited_entries(self) -> None:
        for prohibited in ("mem", "environ", "cmdline", "maps", "stack", "syscall"):
            with self.subTest(entry=prohibited):
                with self.assertRaises(SecurityException):
                    self.reader._safe_proc_path(1234, prohibited)

    def test_real_system_self_proc_inspection(self) -> None:
        real_reader = ProcReader(proc_root="/proc")
        my_pid = os.getpid()
        stat = real_reader.read_stat(my_pid)
        self.assertIsNotNone(stat)
        assert stat is not None
        self.assertEqual(stat.pid, my_pid)
        self.assertIn(stat.state, ("R", "S", "D"))
        self.assertGreaterEqual(real_reader.cpu_time_ms(stat), 0)
        self.assertGreater(real_reader.rss_bytes(stat), 0)
        self.assertTrue(real_reader.is_pid_alive(my_pid))


if __name__ == "__main__":
    unittest.main()
