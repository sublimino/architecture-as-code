"""Data models and representations for bounded host process telemetry."""
from __future__ import annotations

import datetime
from enum import Enum
import json
import re
from typing import Any, Dict, List, Optional, Tuple, Union


class HealthState(str, Enum):
    """Allowlisted process health states."""
    STARTING = "starting"
    RUNNING = "running"
    STOPPED = "stopped"
    FAILED = "failed"
    UNKNOWN = "unknown"


class EvidenceType(str, Enum):
    """Signal Loom evidence types."""
    PROCESS = "process"
    ARTIFACT = "artifact"
    NETWORK = "network"
    COLLECTION_LIMIT = "collection-limit"


class ObservationState(str, Enum):
    """Signal Loom observation states."""
    OBSERVED = "observed"
    DENIED = "denied"
    UNOBSERVED = "unobserved"


class IntegrityState(str, Enum):
    """Signal Loom integrity states."""
    VERIFIED = "integrity-verified"
    NOT_VERIFIED = "not-integrity-verified"


class ExportSource(str, Enum):
    """Approved telemetry sources."""
    HOST_SENSOR = "host-sensor-v1"
    NONO = "nono-0.73.0"
    SIGNAL_INGEST = "signal-ingest"


RFC3339_REGEX = re.compile(
    r"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])"
    r"T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?"
    r"(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
)

SESSION_ID_REGEX = re.compile(r"^[a-zA-Z0-9-]{3,128}$")
ENTITY_ID_REGEX = re.compile(r"^[a-z][a-z0-9-]{2,63}$")


class BoundedProcessAttributes:
    """Allowlisted process lifecycle attributes.

    Strictly restricted to non-sensitive metrics: health state, CPU time,
    resident memory bytes, exit code, restart count, and optional CPU percent.
    Zero process memory or command payload bytes are collected or stored.
    """

    def __init__(
        self,
        health_state: Union[HealthState, str],
        cpu_time_ms: int,
        resident_memory_bytes: int,
        exit_code: Optional[int] = None,
        restart_count: int = 0,
        cpu_percent: Optional[float] = None,
        pid: Optional[int] = None,
        ppid: Optional[int] = None,
    ) -> None:
        if isinstance(health_state, str):
            health_state = HealthState(health_state)
        self.health_state: HealthState = health_state
        self.cpu_time_ms: int = int(cpu_time_ms)
        self.resident_memory_bytes: int = int(resident_memory_bytes)
        self.exit_code: Optional[int] = int(exit_code) if exit_code is not None else None
        self.restart_count: int = int(restart_count)
        self.cpu_percent: Optional[float] = (
            round(float(cpu_percent), 2) if cpu_percent is not None else None
        )
        self.pid: Optional[int] = int(pid) if pid is not None else None
        self.ppid: Optional[int] = int(ppid) if ppid is not None else None
        self.validate()

    def validate(self) -> None:
        """Validate attribute bounds against schema constraints."""
        if not isinstance(self.health_state, HealthState):
            raise ValueError(f"Invalid health_state: {self.health_state}")
        if self.cpu_time_ms < 0 or self.cpu_time_ms > 9007199254740991:
            raise ValueError(f"cpu_time_ms out of bounds: {self.cpu_time_ms}")
        if self.resident_memory_bytes < 0 or self.resident_memory_bytes > 9007199254740991:
            raise ValueError(f"resident_memory_bytes out of bounds: {self.resident_memory_bytes}")
        if self.restart_count < 0 or self.restart_count > 9007199254740991:
            raise ValueError(f"restart_count out of bounds: {self.restart_count}")
        if self.exit_code is not None and not (-2147483648 <= self.exit_code <= 2147483647):
            raise ValueError(f"exit_code out of int32 range: {self.exit_code}")
        if self.cpu_percent is not None and self.cpu_percent < 0.0:
            raise ValueError(f"cpu_percent must be non-negative: {self.cpu_percent}")

    def to_export_dict(self) -> Dict[str, Any]:
        """Convert to canonical Signal evidence attributes dict.

        Includes only the 5 frozen attributes required by external-agent-evidence schema.
        """
        return {
            "health_state": self.health_state.value,
            "cpu_time_ms": self.cpu_time_ms,
            "resident_memory_bytes": self.resident_memory_bytes,
            "exit_code": self.exit_code,
            "restart_count": self.restart_count,
        }

    def to_dict(self, include_extended: bool = False) -> Dict[str, Any]:
        """Convert to dictionary, optionally including non-sensitive extended metrics."""
        result = self.to_export_dict()
        if include_extended:
            if self.cpu_percent is not None:
                result["cpu_percent"] = self.cpu_percent
            if self.pid is not None:
                result["pid"] = self.pid
            if self.ppid is not None:
                result["ppid"] = self.ppid
        return result

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "BoundedProcessAttributes":
        """Construct instance from dictionary."""
        return cls(
            health_state=data["health_state"],
            cpu_time_ms=data["cpu_time_ms"],
            resident_memory_bytes=data["resident_memory_bytes"],
            exit_code=data.get("exit_code"),
            restart_count=data.get("restart_count", 0),
            cpu_percent=data.get("cpu_percent"),
            pid=data.get("pid"),
            ppid=data.get("ppid"),
        )

    def __eq__(self, other: Any) -> bool:
        if not isinstance(other, BoundedProcessAttributes):
            return False
        return (
            self.health_state == other.health_state
            and self.cpu_time_ms == other.cpu_time_ms
            and self.resident_memory_bytes == other.resident_memory_bytes
            and self.exit_code == other.exit_code
            and self.restart_count == other.restart_count
            and self.cpu_percent == other.cpu_percent
            and self.pid == other.pid
            and self.ppid == other.ppid
        )

    def __repr__(self) -> str:
        return (
            f"BoundedProcessAttributes(health_state={self.health_state.value!r}, "
            f"cpu_time_ms={self.cpu_time_ms}, resident_memory_bytes={self.resident_memory_bytes}, "
            f"exit_code={self.exit_code}, restart_count={self.restart_count}, "
            f"cpu_percent={self.cpu_percent}, pid={self.pid}, ppid={self.ppid})"
        )


class ProcessTelemetryEvent:
    """Envelope for versioned process lifecycle evidence record."""

    def __init__(
        self,
        session_id: str,
        sequence: int,
        observed_at: Union[str, datetime.datetime],
        agent_id: str,
        host_id: str,
        attributes: Union[BoundedProcessAttributes, Dict[str, Any]],
        schema_version: str = "1.0.0",
        source: Union[ExportSource, str] = ExportSource.HOST_SENSOR,
        evidence_type: Union[EvidenceType, str] = EvidenceType.PROCESS,
        observation_state: Union[ObservationState, str] = ObservationState.OBSERVED,
        integrity_state: Union[IntegrityState, str] = IntegrityState.NOT_VERIFIED,
        tenant_id: Optional[str] = None,
    ) -> None:
        self.schema_version: str = str(schema_version)
        self.session_id: str = str(session_id)
        self.sequence: int = int(sequence)

        if isinstance(observed_at, datetime.datetime):
            if observed_at.tzinfo is None:
                observed_at = observed_at.replace(tzinfo=datetime.timezone.utc)
            self.observed_at: str = observed_at.isoformat()
        else:
            self.observed_at = str(observed_at)

        self.source: ExportSource = (
            source if isinstance(source, ExportSource) else ExportSource(source)
        )
        self.evidence_type: EvidenceType = (
            evidence_type if isinstance(evidence_type, EvidenceType) else EvidenceType(evidence_type)
        )
        self.observation_state: ObservationState = (
            observation_state
            if isinstance(observation_state, ObservationState)
            else ObservationState(observation_state)
        )
        self.integrity_state: IntegrityState = (
            integrity_state
            if isinstance(integrity_state, IntegrityState)
            else IntegrityState(integrity_state)
        )
        self.tenant_id: Optional[str] = str(tenant_id) if tenant_id is not None else None
        self.agent_id: str = str(agent_id)
        self.host_id: str = str(host_id)

        if isinstance(attributes, BoundedProcessAttributes):
            self.attributes: BoundedProcessAttributes = attributes
        elif isinstance(attributes, dict):
            self.attributes = BoundedProcessAttributes.from_dict(attributes)
        else:
            raise TypeError(f"Invalid attributes type: {type(attributes)}")

        self.validate()

    def validate(self) -> None:
        """Validate envelope and attribute fields."""
        if self.schema_version != "1.0.0":
            raise ValueError(f"schema_version must be '1.0.0', got '{self.schema_version}'")
        if not SESSION_ID_REGEX.match(self.session_id):
            raise ValueError(f"Invalid session_id pattern: '{self.session_id}'")
        if self.sequence < 0 or self.sequence > 9007199254740991:
            raise ValueError(f"sequence out of bounds: {self.sequence}")
        if not RFC3339_REGEX.match(self.observed_at):
            raise ValueError(f"observed_at must be RFC3339 string, got '{self.observed_at}'")
        if not ENTITY_ID_REGEX.match(self.agent_id):
            raise ValueError(f"Invalid agent_id: '{self.agent_id}'")
        if not ENTITY_ID_REGEX.match(self.host_id):
            raise ValueError(f"Invalid host_id: '{self.host_id}'")
        if self.tenant_id is not None and not ENTITY_ID_REGEX.match(self.tenant_id):
            raise ValueError(f"Invalid tenant_id: '{self.tenant_id}'")
        self.attributes.validate()

    def to_dict(self, include_tenant: bool = False, include_extended: bool = False) -> Dict[str, Any]:
        """Convert to canonical dictionary format."""
        data: Dict[str, Any] = {
            "schema_version": self.schema_version,
            "session_id": self.session_id,
            "sequence": self.sequence,
            "observed_at": self.observed_at,
            "source": self.source.value,
            "evidence_type": self.evidence_type.value,
            "observation_state": self.observation_state.value,
            "integrity_state": self.integrity_state.value,
            "agent_id": self.agent_id,
            "host_id": self.host_id,
            "attributes": self.attributes.to_dict(include_extended=include_extended),
        }
        if include_tenant and self.tenant_id is not None:
            data["tenant_id"] = self.tenant_id
        return data

    def to_json(self, indent: Optional[int] = None, include_tenant: bool = False) -> str:
        """Serialize to deterministic JSON string."""
        return json.dumps(
            self.to_dict(include_tenant=include_tenant),
            indent=indent,
            sort_keys=True,
        )

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ProcessTelemetryEvent":
        """Construct instance from dictionary."""
        return cls(
            schema_version=data.get("schema_version", "1.0.0"),
            session_id=data["session_id"],
            sequence=data["sequence"],
            observed_at=data["observed_at"],
            source=data.get("source", ExportSource.HOST_SENSOR),
            evidence_type=data.get("evidence_type", EvidenceType.PROCESS),
            observation_state=data.get("observation_state", ObservationState.OBSERVED),
            integrity_state=data.get("integrity_state", IntegrityState.NOT_VERIFIED),
            tenant_id=data.get("tenant_id"),
            agent_id=data["agent_id"],
            host_id=data["host_id"],
            attributes=data["attributes"],
        )
