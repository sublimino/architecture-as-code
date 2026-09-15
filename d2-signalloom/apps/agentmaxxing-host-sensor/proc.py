"""Linux /proc filesystem metrics reader with strict zero-payload security invariants."""
from __future__ import annotations

import os
from pathlib import Path
import resource
from typing import Any, Dict, List, NamedTuple, Optional, Tuple, Union


class SecurityException(Exception):
    """Raised when an operation attempts to violate runtime security invariants."""


PROHIBITED_PROC_ENTRIES = {
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
}


class ProcStat(NamedTuple):
    """Raw fields parsed safely from /proc/<pid>/stat."""
    pid: int
    comm: str
    state: str
    ppid: int
    pgrp: int
    session: int
    utime_ticks: int
    stime_ticks: int
    cutime_ticks: int
    cstime_ticks: int
    starttime_ticks: int
    vsize_bytes: int
    rss_pages: int
    exit_code_raw: Optional[int]


class ProcStatm(NamedTuple):
    """Fields parsed safely from /proc/<pid>/statm."""
    size_pages: int
    resident_pages: int
    shared_pages: int
    text_pages: int
    lib_pages: int
    data_pages: int
    dt_pages: int


class ProcStatus(NamedTuple):
    """Key metrics parsed safely from /proc/<pid>/status."""
    name: str
    state: str
    ppid: int
    vm_rss_bytes: Optional[int]
    vm_size_bytes: Optional[int]
    threads: int


class ProcReader:
    """Safe reader for /proc lifecycle metrics without inspecting process payloads."""

    def __init__(
        self,
        proc_root: Union[str, Path] = "/proc",
        page_size: Optional[int] = None,
        clk_tck: Optional[int] = None,
    ) -> None:
        self.proc_root: Path = Path(proc_root)
        self.page_size: int = (
            int(page_size)
            if page_size is not None
            else (
                os.sysconf(os.sysconf_names.get("SC_PAGE_SIZE", "SC_PAGE_SIZE"))
                if hasattr(os, "sysconf")
                else resource.getpagesize()
            )
        )
        self.clk_tck: int = (
            int(clk_tck)
            if clk_tck is not None
            else (
                os.sysconf(os.sysconf_names.get("SC_CLK_TCK", "SC_CLK_TCK"))
                if hasattr(os, "sysconf")
                else 100
            )
        )

    def _safe_proc_path(self, pid: int, entry_name: str) -> Path:
        """Resolve and validate that a proc entry is permitted."""
        if entry_name in PROHIBITED_PROC_ENTRIES:
            raise SecurityException(
                f"Security violation: reading /proc/[pid]/{entry_name} is strictly prohibited "
                "to prevent memory extraction and payload harvesting."
            )
        return self.proc_root / str(pid) / entry_name

    def list_pids(self) -> List[int]:
        """Scan proc_root for active numeric PID directory entries.

        Returns a sorted list of integer PIDs. Handles missing directory or
        permission issues gracefully without raising exceptions.
        """
        if not self.proc_root.exists():
            return []
        pids: List[int] = []
        try:
            for entry in os.scandir(self.proc_root):
                try:
                    if entry.is_dir(follow_symlinks=False) and entry.name.isdigit():
                        pids.append(int(entry.name))
                except (PermissionError, FileNotFoundError, OSError):
                    continue
        except (FileNotFoundError, PermissionError, ProcessLookupError, NotADirectoryError, OSError):
            return []
        return sorted(pids)

    def is_pid_alive(self, pid: int) -> bool:
        """Check if process exists and is active."""
        if pid <= 0:
            return False
        stat_path = self.proc_root / str(pid) / "stat"
        if stat_path.exists():
            return True
        try:
            os.kill(pid, 0)
            return True
        except (ProcessLookupError, PermissionError):
            return False
        except OSError:
            return False

    def read_stat(self, pid: int) -> Optional[ProcStat]:
        """Read and safely parse /proc/<pid>/stat.

        Handles command names containing spaces and nested parentheses.
        """
        stat_file = self._safe_proc_path(pid, "stat")
        try:
            with open(stat_file, "r", encoding="utf-8", errors="replace") as f:
                content = f.read().strip()
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            return None
        except OSError:
            return None

        if not content:
            return None

        # /proc/[pid]/stat format:
        # pid (comm with possible spaces/parentheses) state ppid pgrp session ...
        first_paren = content.find("(")
        last_paren = content.rfind(")")
        if first_paren == -1 or last_paren == -1 or last_paren <= first_paren:
            return None

        try:
            raw_pid = int(content[:first_paren].strip())
        except ValueError:
            return None

        comm = content[first_paren + 1 : last_paren]
        rest = content[last_paren + 1 :].strip().split()

        # In Linux /proc/pid/stat, after comm:
        # rest[0]: state (3)
        # rest[1]: ppid (4)
        # rest[2]: pgrp (5)
        # rest[3]: session (6)
        # rest[11]: utime (14)
        # rest[12]: stime (15)
        # rest[13]: cutime (16)
        # rest[14]: cstime (17)
        # rest[19]: starttime (22)
        # rest[20]: vsize (23)
        # rest[21]: rss (24)
        # rest[49]: exit_code (52) - available on kernels with 52 fields
        if len(rest) < 22:
            return None

        try:
            state = rest[0]
            ppid = int(rest[1])
            pgrp = int(rest[2])
            session = int(rest[3])
            utime = int(rest[11])
            stime = int(rest[12])
            cutime = int(rest[13])
            cstime = int(rest[14])
            starttime = int(rest[19])
            vsize = int(rest[20])
            rss = int(rest[21])
            exit_code = int(rest[49]) if len(rest) > 49 else None

            return ProcStat(
                pid=raw_pid,
                comm=comm,
                state=state,
                ppid=ppid,
                pgrp=pgrp,
                session=session,
                utime_ticks=utime,
                stime_ticks=stime,
                cutime_ticks=cutime,
                cstime_ticks=cstime,
                starttime_ticks=starttime,
                vsize_bytes=vsize,
                rss_pages=rss,
                exit_code_raw=exit_code,
            )
        except (ValueError, IndexError):
            return None

    def read_statm(self, pid: int) -> Optional[ProcStatm]:
        """Read and parse /proc/<pid>/statm."""
        statm_file = self._safe_proc_path(pid, "statm")
        try:
            with open(statm_file, "r", encoding="utf-8") as f:
                content = f.read().strip()
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            return None
        except OSError:
            return None

        parts = content.split()
        if len(parts) < 7:
            return None

        try:
            return ProcStatm(
                size_pages=int(parts[0]),
                resident_pages=int(parts[1]),
                shared_pages=int(parts[2]),
                text_pages=int(parts[3]),
                lib_pages=int(parts[4]),
                data_pages=int(parts[5]),
                dt_pages=int(parts[6]),
            )
        except ValueError:
            return None

    def read_status(self, pid: int) -> Optional[ProcStatus]:
        """Read and safely parse /proc/<pid>/status."""
        status_file = self._safe_proc_path(pid, "status")
        try:
            with open(status_file, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            return None
        except OSError:
            return None

        name = ""
        state = ""
        ppid = 0
        vm_rss = None
        vm_size = None
        threads = 1

        for line in lines:
            if ":" not in line:
                continue
            key, val = line.split(":", 1)
            key = key.strip()
            val = val.strip()
            if key == "Name":
                name = val
            elif key == "State":
                state = val.split()[0] if val else ""
            elif key == "PPid":
                try:
                    ppid = int(val)
                except ValueError:
                    pass
            elif key == "VmRSS":
                parts = val.split()
                if parts:
                    try:
                        vm_rss = int(parts[0]) * 1024
                    except ValueError:
                        pass
            elif key == "VmSize":
                parts = val.split()
                if parts:
                    try:
                        vm_size = int(parts[0]) * 1024
                    except ValueError:
                        pass
            elif key == "Threads":
                try:
                    threads = int(val)
                except ValueError:
                    pass

        return ProcStatus(
            name=name,
            state=state,
            ppid=ppid,
            vm_rss_bytes=vm_rss,
            vm_size_bytes=vm_size,
            threads=threads,
        )

    def cpu_time_ms(self, stat: ProcStat) -> int:
        """Convert total process CPU ticks (utime + stime) to milliseconds."""
        total_ticks = stat.utime_ticks + stat.stime_ticks
        return int((total_ticks * 1000) / self.clk_tck)

    def rss_bytes(self, stat: ProcStat, statm: Optional[ProcStatm] = None) -> int:
        """Convert RSS pages to bytes. Prefers statm if available."""
        if statm is not None:
            return statm.resident_pages * self.page_size
        return stat.rss_pages * self.page_size

    def read_exe(self, pid: int) -> Optional[Path]:
        """Read and safely resolve /proc/<pid>/exe symlink target without inspecting cmdline.

        Returns the resolved Path target of the /proc/<pid>/exe symlink.
        Handles processes whose binary was unlinked/deleted by stripping the
        trailing ' (deleted)' kernel annotation if present.
        Returns None if process does not exist, symlink is missing (e.g. kernel threads),
        or permission is denied.
        """
        try:
            exe_path = self._safe_proc_path(pid, "exe")
            target = os.readlink(exe_path)
            if target.endswith(" (deleted)"):
                target = target[:-10]
            return Path(target)
        except (FileNotFoundError, ProcessLookupError, PermissionError, NotADirectoryError, OSError):
            return None

    def read_exe_basename(self, pid: int) -> Optional[str]:
        """Resolve the binary basename from /proc/<pid>/exe safely without reading cmdline.

        Identifies real executable target even if binary was symlinked or renamed,
        without risking credential exposure from command line arguments.
        """
        exe = self.read_exe(pid)
        if exe is None:
            return None
        return exe.name

