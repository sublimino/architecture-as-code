"""Process telemetry collector orchestrating /proc and cgroups v2 extraction."""
from __future__ import annotations

import datetime
from pathlib import Path
import sys
import time
from typing import Any, Dict, Optional, Tuple, Union

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .cgroups import CgroupV2Reader
    from .filter import AllowlistFilter
    from .models import (
        BoundedProcessAttributes,
        EvidenceType,
        ExportSource,
        HealthState,
        IntegrityState,
        ObservationState,
        ProcessTelemetryEvent,
    )
    from .proc import ProcReader, ProcStat, ProcStatm, ProcStatus
except (ImportError, ValueError):
    from cgroups import CgroupV2Reader
    from filter import AllowlistFilter
    from models import (
        BoundedProcessAttributes,
        EvidenceType,
        ExportSource,
        HealthState,
        IntegrityState,
        ObservationState,
        ProcessTelemetryEvent,
    )
    from proc import ProcReader, ProcStat, ProcStatm, ProcStatus


class ProcessTelemetryCollector:
    """Collects bounded allowlisted process lifecycle metrics from Linux kernel interfaces."""

    def __init__(
        self,
        proc_reader: Optional[ProcReader] = None,
        cgroup_reader: Optional[CgroupV2Reader] = None,
    ) -> None:
        self.proc_reader: ProcReader = proc_reader or ProcReader()
        self.cgroup_reader: CgroupV2Reader = cgroup_reader or CgroupV2Reader()
        # Per-PID history for delta rate calculations: pid -> (last_time, last_cpu_time_ms)
        self._history: Dict[int, Tuple[float, int]] = {}
        # Tracking for detected restarts
        self._restart_counts: Dict[int, int] = {}

    def reset_history(self, pid: Optional[int] = None) -> None:
        """Reset historical CPU sampling state."""
        if pid is not None:
            self._history.pop(pid, None)
            self._restart_counts.pop(pid, None)
        else:
            self._history.clear()
            self._restart_counts.clear()

    def set_restart_count(self, pid: int, count: int) -> None:
        """Explicitly set restart count for a monitored process."""
        self._restart_counts[pid] = max(0, int(count))

    def get_restart_count(self, pid: int) -> int:
        """Get current tracked restart count for process."""
        return self._restart_counts.get(pid, 0)

    def calculate_cpu_percent(
        self,
        pid: int,
        current_cpu_time_ms: int,
        current_time: Optional[float] = None,
    ) -> float:
        """Calculate CPU utilization percentage over sample interval or process lifetime."""
        now = current_time if current_time is not None else time.time()
        prev = self._history.get(pid)
        self._history[pid] = (now, current_cpu_time_ms)

        if prev is None:
            return 0.0

        prev_time, prev_cpu_time_ms = prev
        delta_time_sec = now - prev_time
        if delta_time_sec <= 0.0:
            return 0.0

        delta_cpu_ms = max(0, current_cpu_time_ms - prev_cpu_time_ms)
        delta_time_ms = delta_time_sec * 1000.0

        # CPU percent across available cores (e.g. 100% = 1 core fully saturated)
        percent = (delta_cpu_ms / delta_time_ms) * 100.0
        return round(percent, 2)

    def collect_attributes(
        self,
        pid: int,
        cgroup_path: Optional[Union[str, Path]] = None,
        override_exit_code: Optional[int] = None,
        restart_count: Optional[int] = None,
    ) -> BoundedProcessAttributes:
        """Collect bounded allowlisted metrics for a target process.

        Reads from /proc/<pid> and optional cgroups v2 controller.
        Never touches /proc/<pid>/mem, environment, or commandline payload arguments.
        """
        now = time.time()
        is_alive = self.proc_reader.is_pid_alive(pid)

        # 1. Read /proc/<pid>/stat and /proc/<pid>/statm
        stat: Optional[ProcStat] = self.proc_reader.read_stat(pid)
        statm: Optional[ProcStatm] = self.proc_reader.read_statm(pid)
        status: Optional[ProcStatus] = self.proc_reader.read_status(pid)

        # 2. Check cgroups v2 if path provided or discoverable
        cg_cpu_time_ms: Optional[int] = None
        cg_mem_bytes: Optional[int] = None
        resolved_cgroup: Optional[Path] = None

        if cgroup_path is not None:
            resolved_cgroup = Path(cgroup_path)
        elif is_alive:
            resolved_cgroup = self.cgroup_reader.resolve_cgroup_path_for_pid(
                pid, proc_root=self.proc_reader.proc_root
            )

        if resolved_cgroup is not None and resolved_cgroup.exists():
            cg_metrics = self.cgroup_reader.read_metrics(resolved_cgroup)
            if cg_metrics.cpu_stat is not None:
                cg_cpu_time_ms = cg_metrics.cpu_stat.cpu_time_ms
            if cg_metrics.memory_current_bytes is not None:
                cg_mem_bytes = cg_metrics.memory_current_bytes

        # 3. Derive CPU time and Resident Memory
        cpu_time_ms = 0
        if cg_cpu_time_ms is not None:
            cpu_time_ms = cg_cpu_time_ms
        elif stat is not None:
            cpu_time_ms = self.proc_reader.cpu_time_ms(stat)

        resident_memory_bytes = 0
        if stat is not None:
            resident_memory_bytes = self.proc_reader.rss_bytes(stat, statm)
        elif status is not None and status.vm_rss_bytes is not None:
            resident_memory_bytes = status.vm_rss_bytes
        elif cg_mem_bytes is not None:
            resident_memory_bytes = cg_mem_bytes

        # 4. Calculate CPU percent
        cpu_percent = self.calculate_cpu_percent(pid, cpu_time_ms, current_time=now)

        # 5. Determine Health State and Exit Code
        ppid: Optional[int] = stat.ppid if stat is not None else (status.ppid if status is not None else None)
        exit_code: Optional[int] = override_exit_code

        if is_alive and stat is not None:
            # Process is currently active
            if stat.state in ("R", "S", "D", "I"):
                health_state = HealthState.RUNNING
            elif stat.state in ("T", "t"):
                health_state = HealthState.STOPPED
            elif stat.state == "Z":
                health_state = HealthState.STOPPED
            else:
                health_state = HealthState.RUNNING
            exit_code = None
        else:
            # Process is terminated or not found
            if exit_code is not None:
                health_state = (
                    HealthState.STOPPED if exit_code == 0 else HealthState.FAILED
                )
            elif stat is not None and stat.exit_code_raw is not None:
                exit_code = stat.exit_code_raw
                health_state = (
                    HealthState.STOPPED if exit_code == 0 else HealthState.FAILED
                )
            else:
                health_state = HealthState.UNKNOWN
                exit_code = None

        # 6. Restart count
        actual_restart_count = (
            restart_count
            if restart_count is not None
            else self._restart_counts.get(pid, 0)
        )

        return BoundedProcessAttributes(
            health_state=health_state,
            cpu_time_ms=cpu_time_ms,
            resident_memory_bytes=resident_memory_bytes,
            exit_code=exit_code,
            restart_count=actual_restart_count,
            cpu_percent=cpu_percent,
            pid=pid if is_alive or stat is not None else None,
            ppid=ppid,
        )

    def collect_event(
        self,
        session_id: str,
        sequence: int,
        agent_id: str,
        host_id: str,
        pid: int,
        tenant_id: Optional[str] = None,
        cgroup_path: Optional[Union[str, Path]] = None,
        override_exit_code: Optional[int] = None,
        restart_count: Optional[int] = None,
        integrity_verified: bool = False,
        observed_at: Optional[Union[str, datetime.datetime]] = None,
    ) -> ProcessTelemetryEvent:
        """Collect and construct a full ProcessTelemetryEvent record."""
        attributes = self.collect_attributes(
            pid=pid,
            cgroup_path=cgroup_path,
            override_exit_code=override_exit_code,
            restart_count=restart_count,
        )

        timestamp = observed_at or datetime.datetime.now(datetime.timezone.utc).isoformat()

        return ProcessTelemetryEvent(
            schema_version="1.0.0",
            session_id=session_id,
            sequence=sequence,
            observed_at=timestamp,
            source=ExportSource.HOST_SENSOR,
            evidence_type=EvidenceType.PROCESS,
            observation_state=ObservationState.OBSERVED,
            integrity_state=(
                IntegrityState.VERIFIED
                if integrity_verified
                else IntegrityState.NOT_VERIFIED
            ),
            tenant_id=tenant_id,
            agent_id=agent_id,
            host_id=host_id,
            attributes=attributes,
        )
