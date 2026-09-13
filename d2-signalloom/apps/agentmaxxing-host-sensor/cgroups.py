"""Linux cgroups v2 resource metrics reader with bounded extraction."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, NamedTuple, Optional, Union


class CgroupCpuStat(NamedTuple):
    """CPU metrics parsed from cgroups v2 cpu.stat."""
    usage_usec: int
    user_usec: int
    system_usec: int

    @property
    def cpu_time_ms(self) -> int:
        """Total CPU time consumed in milliseconds."""
        return self.usage_usec // 1000


class CgroupMetrics(NamedTuple):
    """Bounded aggregate metrics from cgroup v2 controller."""
    cpu_stat: Optional[CgroupCpuStat]
    memory_current_bytes: Optional[int]
    pids_current: Optional[int]


class CgroupV2Reader:
    """Reader for Linux cgroups v2 unified controller hierarchy."""

    def __init__(self, cgroup_root: Union[str, Path] = "/sys/fs/cgroup") -> None:
        self.cgroup_root: Path = Path(cgroup_root)

    def resolve_cgroup_path_for_pid(
        self,
        pid: int,
        proc_root: Union[str, Path] = "/proc",
    ) -> Optional[Path]:
        """Read /proc/<pid>/cgroup and resolve corresponding cgroup v2 directory path."""
        cgroup_file = Path(proc_root) / str(pid) / "cgroup"
        try:
            with open(cgroup_file, "r", encoding="utf-8") as f:
                lines = f.readlines()
        except (FileNotFoundError, ProcessLookupError, PermissionError, OSError):
            return None

        # Format for cgroup v2: "0::$PATH"
        for line in lines:
            line = line.strip()
            if line.startswith("0::"):
                rel_path = line[3:].lstrip("/")
                full_path = self.cgroup_root / rel_path
                return full_path if full_path.exists() else None
            parts = line.split(":")
            if len(parts) == 3 and parts[0] == "0":
                rel_path = parts[2].lstrip("/")
                full_path = self.cgroup_root / rel_path
                return full_path if full_path.exists() else None
        return None

    def read_cpu_stat(self, cgroup_dir: Union[str, Path]) -> Optional[CgroupCpuStat]:
        """Read and parse cpu.stat from cgroup directory."""
        cpu_stat_file = Path(cgroup_dir) / "cpu.stat"
        try:
            with open(cpu_stat_file, "r", encoding="utf-8") as f:
                lines = f.readlines()
        except (FileNotFoundError, PermissionError, OSError):
            return None

        usage_usec = 0
        user_usec = 0
        system_usec = 0

        for line in lines:
            parts = line.strip().split()
            if len(parts) == 2:
                key, val = parts[0], parts[1]
                try:
                    val_int = int(val)
                    if key == "usage_usec":
                        usage_usec = val_int
                    elif key == "user_usec":
                        user_usec = val_int
                    elif key == "system_usec":
                        system_usec = val_int
                except ValueError:
                    pass

        return CgroupCpuStat(
            usage_usec=usage_usec,
            user_usec=user_usec,
            system_usec=system_usec,
        )

    def read_memory_current(self, cgroup_dir: Union[str, Path]) -> Optional[int]:
        """Read memory.current (in bytes) from cgroup directory."""
        mem_file = Path(cgroup_dir) / "memory.current"
        try:
            with open(mem_file, "r", encoding="utf-8") as f:
                content = f.read().strip()
            return int(content)
        except (FileNotFoundError, PermissionError, ValueError, OSError):
            return None

    def read_pids_current(self, cgroup_dir: Union[str, Path]) -> Optional[int]:
        """Read pids.current (number of tasks) from cgroup directory."""
        pids_file = Path(cgroup_dir) / "pids.current"
        try:
            with open(pids_file, "r", encoding="utf-8") as f:
                content = f.read().strip()
            return int(content)
        except (FileNotFoundError, PermissionError, ValueError, OSError):
            return None

    def read_metrics(self, cgroup_dir: Union[str, Path]) -> CgroupMetrics:
        """Collect bounded aggregate metrics from cgroup v2."""
        cgroup_path = Path(cgroup_dir)
        return CgroupMetrics(
            cpu_stat=self.read_cpu_stat(cgroup_path),
            memory_current_bytes=self.read_memory_current(cgroup_path),
            pids_current=self.read_pids_current(cgroup_path),
        )
