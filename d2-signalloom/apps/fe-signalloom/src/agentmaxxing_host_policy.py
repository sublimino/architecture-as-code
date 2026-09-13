"""Frozen AMXO-P1-2 host policy and pre-persistence export boundary.

This module does not verify nono audit chains. The Go ``agentnono`` collector
remains the sole session-integrity authority. The functions here constrain the
metadata that a later ingestion card may persist or export.
"""
from __future__ import annotations

import json
from enum import Enum
from pathlib import Path
from typing import Annotated, Any, Literal

from pydantic import (
    AwareDatetime,
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    model_validator,
)


def _require_datetime_string(value: Any) -> Any:
    if not isinstance(value, str):
        raise ValueError("timestamp must be an RFC 3339 string")
    return value


Rfc3339Datetime = Annotated[AwareDatetime, BeforeValidator(_require_datetime_string)]


class _ClosedModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class Approval(_ClosedModel):
    approver: str = Field(min_length=1)
    approved_at: Rfc3339Datetime
    provenance: Literal["AMXO-P1-2 task contract"]
    scope: Literal["host-confinement-and-privacy-v1"]


class NonoProfile(_ClosedModel):
    name: Literal["agentmaxxing-linux-v1"]
    version: Literal["0.73.0"]
    fail_closed: Literal[True]
    landlock_required: Literal[True]
    network_proxy_required: Literal[True]


class HostIdentity(_ClosedModel):
    host_owner: Literal["AgentMaxxing Incorporated"]
    service_account: Literal["agentmaxxing-sensor"]
    systemd_unit: Literal["agentmaxxing-agent.service"]
    tenant_id: Literal["tenant-agentmaxxing"]
    agent_id: Literal["agentmaxxing-linux-001"]
    host_id: Literal["amx-host-001"]


class ApprovedRoot(_ClosedModel):
    root_id: str = Field(pattern=r"^[a-z][a-z0-9-]{2,31}$")
    path: str = Field(pattern=r"^/[^*?\[\]]+$")
    artifact_hashing: bool


class NetworkDestination(_ClosedModel):
    destination_id: str = Field(pattern=r"^[a-z][a-z0-9-]{2,31}$")
    dns_name: str = Field(pattern=r"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])$")
    transport: Literal["tcp"]
    port: Literal[443]
    tls_required: Literal[True]


class ArtifactAccess(_ClosedModel):
    syscall: Literal["openat2"]
    root_descriptor_pinning: Literal["service-lifetime"]
    resolve_flags: tuple[
        Literal["RESOLVE_BENEATH"],
        Literal["RESOLVE_NO_SYMLINKS"],
        Literal["RESOLVE_NO_XDEV"],
    ]
    require_regular_file: Literal[True]
    required_link_count: Literal[1]
    require_same_mount_id: Literal[True]
    pre_hash_identity_fields: tuple[
        Literal["inode"],
        Literal["mount_id"],
        Literal["link_count"],
        Literal["size"],
        Literal["mtime_ns"],
        Literal["ctime_ns"],
    ]
    revalidate_after_hash: Literal[True]
    hash_validated_descriptor_only: Literal[True]


class HashingLimits(_ClosedModel):
    algorithm: Literal["sha256"]
    max_file_size_bytes: Literal[16777216]
    max_files_per_window: Literal[120]
    max_bytes_per_window: Literal[67108864]
    window_seconds: Literal[60]
    oversize_state: Literal["unobserved"]
    rate_limited_state: Literal["unobserved"]


class Lifecycle(_ClosedModel):
    evidence_retention_days: Literal[30]
    deletion_deadline_days: Literal[7]
    retention_owner: Literal["ControlPlane Signal Loom Operations"]
    deletion_owner: Literal["ControlPlane Signal Loom Operations"]
    host_unenrollment_owner: Literal["AgentMaxxing Platform Engineering"]
    deletion_trigger: Literal["verified-tenant-request-or-host-unenrollment"]


class PrivacyBoundary(_ClosedModel):
    unobserved_fields: tuple[
        Literal["read_only_input_file_digests"],
        Literal["file_contents"],
        Literal["process_memory_contents"],
        Literal["in_memory_synthesis_contents"],
        Literal["streamed_payload_digests"],
        Literal["streamed_payload_contents"],
        Literal["network_payload_contents"],
    ]
    prohibited_export_fields: tuple[
        Literal["raw_nono_record"],
        Literal["command"],
        Literal["path"],
        Literal["url"],
        Literal["error"],
        Literal["file_contents"],
        Literal["memory_contents"],
        Literal["streamed_payload_digest"],
        Literal["streamed_payload_contents"],
        Literal["network_payload_contents"],
    ]
    raw_paths_exported: Literal[False]
    raw_urls_exported: Literal[False]
    raw_errors_exported: Literal[False]
    integrity_implies_completeness: Literal[False]
    integrity_implies_host_trust: Literal[False]


class HostPolicy(_ClosedModel):
    schema_version: Literal["1.0.0"]
    policy_id: Literal["amxo-host-policy-v1"]
    approval: Approval
    nono: NonoProfile
    host: HostIdentity
    readable_roots: tuple[ApprovedRoot, ...] = Field(min_length=1)
    writable_roots: tuple[ApprovedRoot, ...] = Field(min_length=1)
    network_destinations: tuple[NetworkDestination, ...] = Field(min_length=1)
    artifact_access: ArtifactAccess
    hashing: HashingLimits
    lifecycle: Lifecycle
    privacy: PrivacyBoundary

    @model_validator(mode="after")
    def validate_unique_boundaries(self) -> "HostPolicy":
        roots = (*self.readable_roots, *self.writable_roots)
        root_ids = [root.root_id for root in roots]
        root_paths = [root.path for root in roots]
        destinations = [item.destination_id for item in self.network_destinations]
        endpoint_tuples = [
            (item.dns_name, item.transport, item.port)
            for item in self.network_destinations
        ]
        if len(root_ids) != len(set(root_ids)):
            raise ValueError("approved root IDs must be unique")
        if len(root_paths) != len(set(root_paths)):
            raise ValueError("approved root paths must be unique")
        if len(destinations) != len(set(destinations)):
            raise ValueError("network destination IDs must be unique")
        if len(endpoint_tuples) != len(set(endpoint_tuples)):
            raise ValueError("network destination tuples must be unique")
        expected_readable = (
            ("agent-install", "/opt/agentmaxxing", False),
            ("system-trust", "/etc/ssl/certs", False),
            ("customer-input", "/srv/agentmaxxing/input", False),
        )
        expected_writable = (
            ("agent-work", "/var/lib/agentmaxxing/work", True),
            ("agent-output", "/var/lib/agentmaxxing/output", True),
            ("nono-audit", "/var/lib/agentmaxxing/audit", False),
        )
        expected_destinations = (
            (
                "signal-loom-ingest",
                "signal-ingest.signalloom.controlplane.io",
                "tcp",
                443,
                True,
            ),
            ("agentmaxxing-api", "api.agentmaxxing.com", "tcp", 443, True),
        )
        readable = tuple(
            (root.root_id, root.path, root.artifact_hashing)
            for root in self.readable_roots
        )
        writable = tuple(
            (root.root_id, root.path, root.artifact_hashing)
            for root in self.writable_roots
        )
        destination_values = tuple(
            (
                item.destination_id,
                item.dns_name,
                item.transport,
                item.port,
                item.tls_required,
            )
            for item in self.network_destinations
        )
        if readable != expected_readable:
            raise ValueError("readable roots must exactly match the frozen policy")
        if writable != expected_writable:
            raise ValueError("writable roots must exactly match the frozen policy")
        if destination_values != expected_destinations:
            raise ValueError("network destinations must exactly match the frozen policy")
        return self


class ObservationState(str, Enum):
    OBSERVED = "observed"
    DENIED = "denied"
    UNOBSERVED = "unobserved"


class IntegrityState(str, Enum):
    VERIFIED = "integrity-verified"
    NOT_VERIFIED = "not-integrity-verified"


class BoundaryClassification(_ClosedModel):
    observation_state: ObservationState
    integrity_state: IntegrityState


class AttributableIdentity(_ClosedModel):
    tenant_id: str = Field(pattern=r"^[a-z][a-z0-9-]{2,63}$")
    agent_id: str = Field(pattern=r"^[a-z][a-z0-9-]{2,63}$")
    host_id: str = Field(pattern=r"^[a-z][a-z0-9-]{2,63}$")


class EvidenceType(str, Enum):
    PROCESS = "process"
    ARTIFACT = "artifact"
    NETWORK = "network"
    COLLECTION_LIMIT = "collection-limit"


class ExportSource(str, Enum):
    NONO = "nono-0.73.0"
    HOST_SENSOR = "host-sensor-v1"
    SIGNAL_INGEST = "signal-ingest"


class ProcessAttributes(_ClosedModel):
    health_state: Literal["starting", "running", "stopped", "failed", "unknown"]
    cpu_time_ms: int = Field(ge=0)
    resident_memory_bytes: int = Field(ge=0)
    exit_code: int | None
    restart_count: int = Field(ge=0)


class ArtifactAttributes(_ClosedModel):
    artifact_id: str = Field(pattern=r"^hmac-sha256:[0-9a-f]{64}$")
    root_id: str = Field(pattern=r"^[a-z][a-z0-9-]{2,31}$")
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    size_bytes: int = Field(ge=0, le=16777216)
    mtime_ns: int = Field(ge=0)


class NetworkAttributes(_ClosedModel):
    destination_id: Literal["signal-loom-ingest", "agentmaxxing-api"]
    decision: Literal["allowed", "denied"]


class CollectionLimitAttributes(_ClosedModel):
    reason_code: Literal["oversize", "files-rate-exhausted", "bytes-rate-exhausted"]
    max_file_size_bytes: Literal[16777216]
    max_files_per_window: Literal[120]
    max_bytes_per_window: Literal[67108864]
    window_seconds: Literal[60]


class AllowlistedExport(_ClosedModel):
    schema_version: Literal["1.0.0"]
    session_id: str = Field(pattern=r"^[a-zA-Z0-9-]{3,128}$")
    sequence: int = Field(ge=0)
    observed_at: Rfc3339Datetime
    source: ExportSource
    evidence_type: EvidenceType
    observation_state: ObservationState
    integrity_state: IntegrityState
    tenant_id: str = Field(pattern=r"^[a-z][a-z0-9-]{2,63}$")
    agent_id: str = Field(pattern=r"^[a-z][a-z0-9-]{2,63}$")
    host_id: str = Field(pattern=r"^[a-z][a-z0-9-]{2,63}$")
    attributes: dict[str, Any]


_COMMON_EXPORT_FIELDS = (
    "schema_version",
    "session_id",
    "sequence",
    "observed_at",
    "source",
    "evidence_type",
    "observation_state",
    "integrity_state",
)

_ATTRIBUTE_ALLOWLIST: dict[EvidenceType, tuple[str, ...]] = {
    EvidenceType.PROCESS: (
        "cpu_time_ms",
        "exit_code",
        "health_state",
        "resident_memory_bytes",
        "restart_count",
    ),
    EvidenceType.ARTIFACT: (
        "artifact_id",
        "mtime_ns",
        "root_id",
        "sha256",
        "size_bytes",
    ),
    EvidenceType.NETWORK: (
        "decision",
        "destination_id",
    ),
    EvidenceType.COLLECTION_LIMIT: (
        "max_bytes_per_window",
        "max_file_size_bytes",
        "max_files_per_window",
        "reason_code",
        "window_seconds",
    ),
}

_ATTRIBUTE_MODELS: dict[EvidenceType, type[_ClosedModel]] = {
    EvidenceType.PROCESS: ProcessAttributes,
    EvidenceType.ARTIFACT: ArtifactAttributes,
    EvidenceType.NETWORK: NetworkAttributes,
    EvidenceType.COLLECTION_LIMIT: CollectionLimitAttributes,
}


def load_host_policy(path: Path) -> HostPolicy:
    """Load and strictly validate one frozen host-policy fixture."""
    with path.open(encoding="utf-8") as handle:
        return HostPolicy.model_validate(json.load(handle))


def classify_boundary(
    *,
    observed: bool = False,
    denied: bool = False,
    integrity_verified: bool = False,
) -> BoundaryClassification:
    """Classify observation independently from integrity verification."""
    if observed and denied:
        raise ValueError("evidence cannot be both observed and denied")
    if denied:
        observation_state = ObservationState.DENIED
    elif observed:
        observation_state = ObservationState.OBSERVED
    else:
        observation_state = ObservationState.UNOBSERVED
    integrity_state = (
        IntegrityState.VERIFIED
        if integrity_verified
        else IntegrityState.NOT_VERIFIED
    )
    return BoundaryClassification(
        observation_state=observation_state,
        integrity_state=integrity_state,
    )


def filter_host_telemetry(
    raw_record: dict[str, Any],
    identity: AttributableIdentity,
    policy: HostPolicy,
) -> dict[str, Any]:
    """Create a deterministic allowlisted export before any persistence.

    Tenant, agent, and host identifiers always come from the authenticated
    server-side binding passed as ``identity``. Unknown input fields are never
    copied, even when nested under ``attributes``.
    """
    evidence_type = EvidenceType(raw_record.get("evidence_type"))
    source = ExportSource(raw_record.get("source"))
    observation_state = ObservationState(raw_record.get("observation_state"))
    integrity_state = IntegrityState(raw_record.get("integrity_state"))

    expected_identity = (
        policy.host.tenant_id,
        policy.host.agent_id,
        policy.host.host_id,
    )
    actual_identity = (identity.tenant_id, identity.agent_id, identity.host_id)
    if actual_identity != expected_identity:
        raise ValueError("server identity does not match the frozen registration")
    if (
        evidence_type is EvidenceType.COLLECTION_LIMIT
        and observation_state is not ObservationState.UNOBSERVED
    ):
        raise ValueError("collection-limit evidence must be unobserved")

    missing = [field for field in _COMMON_EXPORT_FIELDS if field not in raw_record]
    if missing:
        raise ValueError(f"telemetry missing required safe fields: {', '.join(missing)}")
    exported = {field: raw_record[field] for field in _COMMON_EXPORT_FIELDS}
    exported["source"] = source.value
    exported["evidence_type"] = evidence_type.value
    exported["observation_state"] = observation_state.value
    exported["integrity_state"] = integrity_state.value
    exported["tenant_id"] = identity.tenant_id
    exported["agent_id"] = identity.agent_id
    exported["host_id"] = identity.host_id

    raw_attributes = raw_record.get("attributes")
    if not isinstance(raw_attributes, dict):
        raise ValueError("telemetry attributes must be an object")
    selected_attributes = {
        field: raw_attributes[field]
        for field in _ATTRIBUTE_ALLOWLIST[evidence_type]
        if field in raw_attributes
    }
    attributes = _ATTRIBUTE_MODELS[evidence_type].model_validate(
        selected_attributes
    )
    if evidence_type is EvidenceType.ARTIFACT:
        hashable_root_ids = {
            root.root_id
            for root in policy.writable_roots
            if root.artifact_hashing
        }
        if attributes.root_id not in hashable_root_ids:
            raise ValueError("artifact root is not approved for hashing")
    if evidence_type is EvidenceType.NETWORK:
        approved_destination_ids = {
            item.destination_id for item in policy.network_destinations
        }
        if attributes.destination_id not in approved_destination_ids:
            raise ValueError("network destination is not approved")
    exported["attributes"] = attributes.model_dump(mode="json")
    return AllowlistedExport.model_validate(exported).model_dump(mode="json")
