"""Host sensor coordinator managing continuous telemetry collection and process lifecycle."""
from __future__ import annotations

import datetime
from pathlib import Path
import sys
import time
from typing import Callable, Iterator, List, Optional, Union

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .collector import ProcessTelemetryCollector
    from .filter import (
        DEFAULT_OBJECTION_REGISTRY,
        SubjectObjectionError,
        SubjectObjectionRegistry,
    )
    from .models import (
        BoundedProcessAttributes,
        HealthState,
        ProcessTelemetryEvent,
    )
except (ImportError, ValueError):
    from collector import ProcessTelemetryCollector
    from filter import (
        DEFAULT_OBJECTION_REGISTRY,
        SubjectObjectionError,
        SubjectObjectionRegistry,
    )
    from models import (
        BoundedProcessAttributes,
        HealthState,
        ProcessTelemetryEvent,
    )


class HostSensor:
    """Coordinates host process monitoring, sequence numbering, and lifecycle tracking."""

    def __init__(
        self,
        session_id: str,
        agent_id: str,
        host_id: str,
        tenant_id: Optional[str] = None,
        collector: Optional[ProcessTelemetryCollector] = None,
        objection_registry: Optional[SubjectObjectionRegistry] = None,
        initial_sequence: int = 0,
    ) -> None:
        self.session_id: str = session_id
        self.agent_id: str = agent_id
        self.host_id: str = host_id
        self.tenant_id: Optional[str] = tenant_id
        self.collector: ProcessTelemetryCollector = collector or ProcessTelemetryCollector()
        self.objection_registry: SubjectObjectionRegistry = objection_registry or DEFAULT_OBJECTION_REGISTRY
        self.sequence: int = initial_sequence
        self._current_pid: Optional[int] = None
        self._restart_count: int = 0
        self._is_running: bool = False

    def is_opted_out(self) -> bool:
        """Check if the monitored agent/actor is opted out under GDPR Article 21."""
        return self.objection_registry.is_opted_out(self.agent_id)

    def bind_pid(self, pid: int, is_restart: bool = False) -> None:
        """Bind or update the monitored PID. Increments restart count if indicated."""
        if self._current_pid is not None and self._current_pid != pid:
            if is_restart:
                self._restart_count += 1
            self.collector.reset_history(self._current_pid)
        self._current_pid = pid
        self.collector.set_restart_count(pid, self._restart_count)

    def record_exit(self, exit_code: int) -> ProcessTelemetryEvent:
        """Record process exit and emit final termination evidence record."""
        if self.is_opted_out():
            raise SubjectObjectionError(self.agent_id, "telemetry recording suppressed on exit")

        event = self.collector.collect_event(
            session_id=self.session_id,
            sequence=self.sequence,
            agent_id=self.agent_id,
            host_id=self.host_id,
            pid=self._current_pid or 0,
            tenant_id=self.tenant_id,
            override_exit_code=exit_code,
            restart_count=self._restart_count,
        )
        self.sequence += 1
        return event

    def sample(
        self,
        cgroup_path: Optional[Union[str, Path]] = None,
        override_exit_code: Optional[int] = None,
    ) -> ProcessTelemetryEvent:
        """Capture single on-demand telemetry snapshot."""
        if self.is_opted_out():
            raise SubjectObjectionError(self.agent_id, "telemetry sample suppressed under Article 21")

        pid = self._current_pid or 0
        event = self.collector.collect_event(
            session_id=self.session_id,
            sequence=self.sequence,
            agent_id=self.agent_id,
            host_id=self.host_id,
            pid=pid,
            tenant_id=self.tenant_id,
            cgroup_path=cgroup_path,
            override_exit_code=override_exit_code,
            restart_count=self._restart_count,
        )
        self.sequence += 1
        return event

    def poll_stream(
        self,
        interval_seconds: float = 1.0,
        max_samples: Optional[int] = None,
        cgroup_path: Optional[Union[str, Path]] = None,
        callback: Optional[Callable[[ProcessTelemetryEvent], None]] = None,
    ) -> Iterator[ProcessTelemetryEvent]:
        """Poll telemetry at regular intervals until max_samples or stopped."""
        samples_taken = 0
        self._is_running = True

        while self._is_running:
            if self.is_opted_out():
                break

            if max_samples is not None and samples_taken >= max_samples:
                break

            event = self.sample(cgroup_path=cgroup_path)
            samples_taken += 1

            if callback is not None:
                callback(event)

            yield event

            # Stop if process has stopped or failed and we've recorded it
            if event.attributes.health_state in (HealthState.STOPPED, HealthState.FAILED):
                break

            time.sleep(interval_seconds)

    def stop(self) -> None:
        """Signal sensor polling loop to stop."""
        self._is_running = False
