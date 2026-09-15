"""
AgentMaxxing Linux Host Sensor & Confinement Package.

Provides defense-in-depth Linux host confinement, fail-closed nono 0.73.0 profiles,
hardened systemd service definitions, bounded allowlisted process telemetry collection,
descriptor-relative artifact anti-escape validation, and rate-limited TOCTOU artifact hashing.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

_PKG_DIR = str(Path(__file__).resolve().parent)
if _PKG_DIR not in sys.path:
    sys.path.insert(0, _PKG_DIR)

try:
    from .cgroups import CgroupV2Reader
    from .classifier import (
        HARNESS_SIGNATURES,
        ClassificationClaim,
        HarnessAncestryClassifier,
        HarnessSignature,
        NullProtocolCorroborator,
        ProtocolCorroborator,
        SessionMarkerCorroborator,
    )
    from .collector import ProcessTelemetryCollector
    from .file_validator import (
        EligibilityStatus,
        PinnedRoot,
        RejectionReason,
        ValidationResult,
        validate_and_hash_artifact,
    )
    from .filter import AllowlistFilter, filter_process_attributes, sanitize_evidence_record
    from .hasher import (
        ArtifactHashResult,
        BoundedArtifactHasher,
        CollectionLimitRecord,
        FileIdentitySnapshot,
        FileOversizeError,
        HasherError,
        InvalidArtifactError,
        RateLimitExceededError,
        TOCTOURaceDetectedError,
    )
    from .models import (
        BoundedProcessAttributes,
        EvidenceType,
        ExportSource,
        HealthState,
        IntegrityState,
        ObservationState,
        ProcessTelemetryEvent,
    )
    from .kanban import (
        CycleObservation,
        CycleObservationSource,
        KanbanCycleExtractor,
        TaskLifecycleTracker,
        get_kanban_home,
        get_kanban_worktrees_home,
        is_kanban_available,
    )
    from .openat2 import get_statx_mnt_id, open_beneath, query_statx
    from .proc import ProcReader
    from .ratelimit import RateLimiter
    from .sensor import HostSensor
except (ImportError, ValueError):
    from cgroups import CgroupV2Reader
    from classifier import (
        HARNESS_SIGNATURES,
        ClassificationClaim,
        HarnessAncestryClassifier,
        HarnessSignature,
        NullProtocolCorroborator,
        ProtocolCorroborator,
        SessionMarkerCorroborator,
    )
    from collector import ProcessTelemetryCollector
    from file_validator import (
        EligibilityStatus,
        PinnedRoot,
        RejectionReason,
        ValidationResult,
        validate_and_hash_artifact,
    )
    from filter import AllowlistFilter, filter_process_attributes, sanitize_evidence_record
    from hasher import (
        ArtifactHashResult,
        BoundedArtifactHasher,
        CollectionLimitRecord,
        FileIdentitySnapshot,
        FileOversizeError,
        HasherError,
        InvalidArtifactError,
        RateLimitExceededError,
        TOCTOURaceDetectedError,
    )
    from models import (
        BoundedProcessAttributes,
        EvidenceType,
        ExportSource,
        HealthState,
        IntegrityState,
        ObservationState,
        ProcessTelemetryEvent,
    )
    from kanban import (
        CycleObservation,
        CycleObservationSource,
        KanbanCycleExtractor,
        TaskLifecycleTracker,
        get_kanban_home,
        get_kanban_worktrees_home,
        is_kanban_available,
    )
    from openat2 import get_statx_mnt_id, open_beneath, query_statx
    from proc import ProcReader
    from ratelimit import RateLimiter
    from sensor import HostSensor

__version__ = "1.0.0"

__all__ = [
    "AllowlistFilter",
    "ArtifactHashResult",
    "BoundedArtifactHasher",
    "BoundedProcessAttributes",
    "CgroupV2Reader",
    "ClassificationClaim",
    "CollectionLimitRecord",
    "CycleObservation",
    "CycleObservationSource",
    "EligibilityStatus",
    "EvidenceType",
    "ExportSource",
    "FileIdentitySnapshot",
    "FileOversizeError",
    "HARNESS_SIGNATURES",
    "HarnessAncestryClassifier",
    "HarnessSignature",
    "HasherError",
    "HealthState",
    "HostSensor",
    "IntegrityState",
    "InvalidArtifactError",
    "KanbanCycleExtractor",
    "NullProtocolCorroborator",
    "ObservationState",
    "PinnedRoot",
    "ProcessTelemetryCollector",
    "ProcessTelemetryEvent",
    "ProcReader",
    "ProtocolCorroborator",
    "RateLimitExceededError",
    "RateLimiter",
    "RejectionReason",
    "SessionMarkerCorroborator",
    "TOCTOURaceDetectedError",
    "TaskLifecycleTracker",
    "ValidationResult",
    "filter_process_attributes",
    "get_kanban_home",
    "get_kanban_worktrees_home",
    "get_statx_mnt_id",
    "is_kanban_available",
    "open_beneath",
    "query_statx",
    "sanitize_evidence_record",
    "validate_and_hash_artifact",
]
