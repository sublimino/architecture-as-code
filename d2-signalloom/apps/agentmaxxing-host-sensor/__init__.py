"""AgentMaxxing Host Sensor — Bounded Process Lifecycle Telemetry Collector.

Emits bounded allowlisted process lifecycle metadata (health state, CPU time/percent,
RSS memory, exit codes, restart count) without inspecting process memory, commandline
arguments, environment variables, customer files, or payload contents.
"""
from __future__ import annotations

from .collector import ProcessTelemetryCollector
from .filter import AllowlistFilter, filter_process_attributes, sanitize_evidence_record
from .models import (
    BoundedProcessAttributes,
    EvidenceType,
    ExportSource,
    HealthState,
    IntegrityState,
    ObservationState,
    ProcessTelemetryEvent,
)
from .proc import ProcReader
from .cgroups import CgroupV2Reader
from .sensor import HostSensor

__version__ = "1.0.0"

__all__ = [
    "AllowlistFilter",
    "BoundedProcessAttributes",
    "CgroupV2Reader",
    "EvidenceType",
    "ExportSource",
    "HealthState",
    "HostSensor",
    "IntegrityState",
    "ObservationState",
    "ProcessTelemetryCollector",
    "ProcessTelemetryEvent",
    "ProcReader",
    "filter_process_attributes",
    "sanitize_evidence_record",
]
