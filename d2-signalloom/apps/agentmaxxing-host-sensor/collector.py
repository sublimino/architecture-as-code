"""Process telemetry collector orchestrating /proc and cgroups v2 extraction."""
from __future__ import annotations

import datetime
from pathlib import Path
import sys
import time
from typing import Any, Callable, Dict, Iterator, List, NamedTuple, Optional, Set, Tuple, Union

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .cgroups import CgroupV2Reader
    from .coding_agent_models import ProcessInfo
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
    from .payload_validator import validate_zero_customer_payload
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
    from payload_validator import validate_zero_customer_payload
    from proc import ProcReader, ProcStat, ProcStatm, ProcStatus
    try:
        from coding_agent_models import ProcessInfo
    except (ImportError, ValueError):
        ProcessInfo = None  # type: ignore


class ScannedProcess(NamedTuple):
    """Allowlisted representation of a candidate process discovered during procfs tree scan."""
    pid: int
    ppid: int
    comm: str
    exe_basename: Optional[str]
    stat: ProcStat
    attributes: BoundedProcessAttributes
    starttime_ticks: int


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
        # Tracking for PID reuse detection: pid -> starttime_ticks
        self._process_starttimes: Dict[int, int] = {}

    def reset_history(self, pid: Optional[int] = None) -> None:
        """Reset historical CPU sampling state and PID starttime tracking."""
        if pid is not None:
            self._history.pop(pid, None)
            self._restart_counts.pop(pid, None)
            self._process_starttimes.pop(pid, None)
        else:
            self._history.clear()
            self._restart_counts.clear()
            self._process_starttimes.clear()

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
        known_stat: Optional[ProcStat] = None,
        known_statm: Optional[ProcStatm] = None,
        known_status: Optional[ProcStatus] = None,
    ) -> BoundedProcessAttributes:
        """Collect bounded allowlisted metrics for a target process.

        Reads from /proc/<pid> and optional cgroups v2 controller.
        Never touches /proc/<pid>/mem, environment, or commandline payload arguments.
        """
        now = time.time()
        is_alive = self.proc_reader.is_pid_alive(pid) if known_stat is None else (known_stat.state not in ("Z", "X") if known_stat else False)

        # 1. Read /proc/<pid>/stat and /proc/<pid>/statm (or reuse known structs)
        stat: Optional[ProcStat] = known_stat if known_stat is not None else self.proc_reader.read_stat(pid)
        statm: Optional[ProcStatm] = known_statm if known_statm is not None else self.proc_reader.read_statm(pid)
        status: Optional[ProcStatus] = known_status if known_status is not None else self.proc_reader.read_status(pid)

        # PID reuse check
        if stat is not None:
            prev_starttime = self._process_starttimes.get(pid)
            if prev_starttime is not None and prev_starttime != stat.starttime_ticks:
                self.reset_history(pid)
            self._process_starttimes[pid] = stat.starttime_ticks

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

    def scan_processes(
        self,
        candidate_filter: Optional[Callable[[ProcStat, Optional[str]], bool]] = None,
        max_pids: Optional[int] = None,
        resolve_exe: bool = True,
    ) -> List[ScannedProcess]:
        """Scan the full /proc/ tree for candidate processes.

        Reads /proc/<pid>/stat, /proc/<pid>/status, and /proc/<pid>/statm.
        Never touches command line argument entries or any prohibited proc files.
        Handles PID reuse races by validating starttime generation ticks.
        Skips unreadable or permission-denied PIDs cleanly without raising exceptions.
        """
        discovered: List[ScannedProcess] = []
        pids = self.proc_reader.list_pids()
        if max_pids is not None and max_pids > 0:
            pids = pids[:max_pids]

        for pid in pids:
            try:
                # 1. Read initial stat
                stat = self.proc_reader.read_stat(pid)
                if stat is None:
                    continue

                # 2. PID reuse check
                prev_starttime = self._process_starttimes.get(pid)
                if prev_starttime is not None and prev_starttime != stat.starttime_ticks:
                    self.reset_history(pid)
                self._process_starttimes[pid] = stat.starttime_ticks

                # 3. Resolve exe basename safely without inspecting argument payloads
                exe_basename: Optional[str] = None
                if resolve_exe:
                    exe_basename = self.proc_reader.read_exe_basename(pid)

                # 4. Filter candidate if filter provided
                if candidate_filter is not None and not candidate_filter(stat, exe_basename):
                    continue

                # 5. Read statm and status
                statm = self.proc_reader.read_statm(pid)
                status = self.proc_reader.read_status(pid)

                # 6. Collect bounded attributes
                attrs = self.collect_attributes(
                    pid=pid,
                    known_stat=stat,
                    known_statm=statm,
                    known_status=status,
                )

                # 7. Re-verify starttime generation race check before attribution
                verify_stat = self.proc_reader.read_stat(pid)
                if verify_stat is None or verify_stat.starttime_ticks != stat.starttime_ticks:
                    continue

                discovered.append(
                    ScannedProcess(
                        pid=stat.pid,
                        ppid=stat.ppid,
                        comm=stat.comm,
                        exe_basename=exe_basename,
                        stat=stat,
                        attributes=attrs,
                        starttime_ticks=stat.starttime_ticks,
                    )
                )
            except PermissionError:
                # Skip immediately on PermissionError, zero retries, no content logged
                continue
            except (FileNotFoundError, ProcessLookupError, NotADirectoryError, OSError):
                continue
            except Exception:
                # Defensive guard: no exception escapes scan loop
                continue

        return discovered

    def continuous_scan(
        self,
        interval_s: float = 0.5,
        max_iterations: Optional[int] = None,
        candidate_filter: Optional[Callable[[ProcStat, Optional[str]], bool]] = None,
        yield_callback: Optional[Callable[[List[ScannedProcess]], None]] = None,
        resolve_exe: bool = True,
    ) -> Iterator[List[ScannedProcess]]:
        """Continuously sweep the process table with CPU yielding between iterations.

        Bounds discovery latency to <2s while capping CPU utilization per proposal KPI.
        """
        iteration = 0
        interval = max(0.01, float(interval_s))
        while max_iterations is None or iteration < max_iterations:
            iteration += 1
            batch = self.scan_processes(
                candidate_filter=candidate_filter,
                resolve_exe=resolve_exe,
            )
            if yield_callback is not None:
                yield_callback(batch)
            yield batch
            if max_iterations is not None and iteration >= max_iterations:
                break
            time.sleep(interval)

    def to_process_info(self, scanned: ScannedProcess) -> Optional[ProcessInfo]:
        """Convert a ScannedProcess to the allowlisted ProcessInfo wire model."""
        if ProcessInfo is None:
            return None
        raw_comm = scanned.stat.comm or scanned.comm or "unknown"
        clean_comm = "".join(c for c in raw_comm if c.isalnum() or c in "_.-")[:16] or "unknown"
        total_cpu_ticks = max(0, scanned.stat.utime_ticks + scanned.stat.stime_ticks)
        return ProcessInfo(
            pid=scanned.pid,
            ppid=scanned.ppid,
            comm=clean_comm,
            rss_bytes=scanned.attributes.resident_memory_bytes,
            cpu_ticks=total_cpu_ticks,
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

        event = ProcessTelemetryEvent(
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

        # Pre-export validation gate: reject any record carrying payload or secrets
        validate_zero_customer_payload(event, tenant_id=tenant_id)

        return event
