"""Allowlist filter and privacy boundary enforcement for host telemetry."""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .models import (
        BoundedProcessAttributes,
        EvidenceType,
        ExportSource,
        HealthState,
        IntegrityState,
        ObservationState,
        ProcessTelemetryEvent,
    )
    from .coding_agent_models import (
        CodingAgentTelemetry,
        Harness,
        ProcessInfo,
        KanbanInfo,
        MetricsInfo,
        ToolCounts,
        NetworkInfo,
        CANONICAL_TOOL_KEYS,
        normalize_tool_name,
    )
    from .payload_validator import (
        DEFAULT_VALIDATOR,
        ZeroPayloadSecurityException,
        validate_zero_customer_payload,
    )
except (ImportError, ValueError):
    from models import (
        BoundedProcessAttributes,
        EvidenceType,
        ExportSource,
        HealthState,
        IntegrityState,
        ObservationState,
        ProcessTelemetryEvent,
    )
    from coding_agent_models import (
        CodingAgentTelemetry,
        Harness,
        ProcessInfo,
        KanbanInfo,
        MetricsInfo,
        ToolCounts,
        NetworkInfo,
        CANONICAL_TOOL_KEYS,
        normalize_tool_name,
    )
    from payload_validator import (
        DEFAULT_VALIDATOR,
        ZeroPayloadSecurityException,
        validate_zero_customer_payload,
    )

# Attributes permitted in process lifecycle export
ALLOWLISTED_PROCESS_ATTRIBUTES: Set[str] = {
    "health_state",
    "cpu_time_ms",
    "resident_memory_bytes",
    "exit_code",
    "restart_count",
}

# Non-sensitive diagnostic process attributes
EXTENDED_PROCESS_ATTRIBUTES: Set[str] = {
    *ALLOWLISTED_PROCESS_ATTRIBUTES,
    "cpu_percent",
    "pid",
    "ppid",
}

# Common envelope fields for Signal evidence records
ALLOWLISTED_ENVELOPE_FIELDS: Set[str] = {
    "schema_version",
    "session_id",
    "sequence",
    "observed_at",
    "source",
    "evidence_type",
    "observation_state",
    "integrity_state",
    "agent_id",
    "actor_id",
    "host_id",
    "attributes",
    "tenant_id",
}

# Allowlisted fields for CodingAgentTelemetry event schema
ALLOWLISTED_CODING_AGENT_ENVELOPE_FIELDS: Set[str] = {
    "schema_version",
    "harness",
    "session_id",
    "timestamp",
    "observed_at",
    "tenant_id",
    "agent_id",
    "host_id",
    "process",
    "kanban",
    "metrics",
    "network",
}

ALLOWLISTED_CODING_AGENT_PROCESS_FIELDS: Set[str] = {
    "pid",
    "ppid",
    "comm",
    "rss_bytes",
    "cpu_ticks",
}

ALLOWLISTED_CODING_AGENT_KANBAN_FIELDS: Set[str] = {
    "task_id",
    "shortcode",
    "role",
    "elapsed_s",
}

ALLOWLISTED_CODING_AGENT_METRICS_FIELDS: Set[str] = {
    "step_count",
    "tokens_in",
    "tokens_out",
    "tool_counts",
}

ALLOWLISTED_CODING_AGENT_TOOL_COUNTS_FIELDS: Set[str] = set(CANONICAL_TOOL_KEYS)

ALLOWLISTED_CODING_AGENT_NETWORK_FIELDS: Set[str] = {
    "inference_endpoint",
    "egress_bytes",
}

# Forbidden keys that must NEVER appear in exported evidence records
PROHIBITED_EXPORT_KEYS: Set[str] = {
    "raw_nono_record",
    "command",
    "cmdline",
    "argv",
    "cli_arguments",
    "command_line",
    "path",
    "url",
    "error",
    "file_contents",
    "memory_contents",
    "memory_dump",
    "streamed_payload_digest",
    "streamed_payload_contents",
    "network_payload_contents",
    "network_payload",
    "input_payload",
    "output_payload",
    "env",
    "environ",
    "environment",
    "stack",
    "heap",
    "registers",
    "payload",
    "stdin",
    "stdout",
    "stderr",
    "credentials",
    "secret",
    "token",
    "password",
    "api_key",
    "user_data",
    "prompt_text",
    "completion_text",
}


class SubjectObjectionError(Exception):
    """Raised when telemetry processing is attempted for an opted-out subject under GDPR Article 21."""

    def __init__(self, subject_id: str, reason: str = ""):
        self.subject_id = subject_id
        self.reason = reason
        msg = f"GDPR Article 21 objection active for subject {subject_id}"
        if reason:
            msg += f": {reason}"
        super().__init__(msg)


class SubjectObjection:
    """Represents a data subject's formal Article 21 objection record."""

    def __init__(
        self,
        subject_id: str,
        reason: str = "GDPR Article 21 right to object",
        registered_at: Optional[str] = None,
        active: bool = True,
    ):
        self.subject_id = subject_id
        self.reason = reason
        self.registered_at = registered_at
        self.active = active

    def to_dict(self) -> Dict[str, Any]:
        return {
            "subject_id": self.subject_id,
            "reason": self.reason,
            "registered_at": self.registered_at,
            "active": self.active,
        }


class SubjectObjectionRegistry:
    """Workstation-level registry of Article 21 objections for person-level exclusion."""

    def __init__(self):
        self._objections: Dict[str, SubjectObjection] = {}

    def register(
        self,
        subject_id: str,
        reason: str = "",
        registered_at: Optional[str] = None,
    ) -> SubjectObjection:
        """Register a subject's objection/opt-out."""
        if not subject_id or not str(subject_id).strip():
            raise ValueError("subject_id cannot be empty")
        normalized = str(subject_id).strip()
        obj = SubjectObjection(
            subject_id=normalized,
            reason=reason or "GDPR Article 21 right to object",
            registered_at=registered_at,
            active=True,
        )
        self._objections[normalized] = obj
        return obj

    def revoke(self, subject_id: str) -> bool:
        """Revoke a previously registered objection."""
        normalized = str(subject_id).strip()
        if normalized in self._objections:
            self._objections[normalized].active = False
            return True
        return False

    def is_opted_out(self, subject_id: Optional[str]) -> bool:
        """Check whether a subject ID, username, or alias is opted-out under Art. 21."""
        if not subject_id:
            return False
        normalized = str(subject_id).strip()
        obj = self._objections.get(normalized)
        return obj is not None and obj.active

    def get(self, subject_id: str) -> Optional[SubjectObjection]:
        normalized = str(subject_id).strip()
        return self._objections.get(normalized)

    def list_active(self) -> List[SubjectObjection]:
        return [o for o in self._objections.values() if o.active]


# Default process-level objection registry
DEFAULT_OBJECTION_REGISTRY = SubjectObjectionRegistry()


class AllowlistFilter:
    """Enforces strict field allowlisting, zero-payload isolation, and Article 21 opt-outs."""

    @staticmethod
    def contains_prohibited_data(data: Any) -> Tuple[bool, List[str]]:
        """Check if dictionary or object contains prohibited keys at any nesting level."""
        found: List[str] = []
        if isinstance(data, dict):
            for key, val in data.items():
                k_str = str(key).lower()
                is_token_secret = "token" in k_str and k_str not in {"tokens_in", "tokens_out"}
                if key in PROHIBITED_EXPORT_KEYS or "secret" in k_str or "password" in k_str or is_token_secret:
                    found.append(f"key:{key}")
                if isinstance(val, (dict, list)):
                    sub_found, sub_keys = AllowlistFilter.contains_prohibited_data(val)
                    if sub_found:
                        found.extend(sub_keys)
        elif isinstance(data, list):
            for item in data:
                if isinstance(item, (dict, list)):
                    sub_found, sub_keys = AllowlistFilter.contains_prohibited_data(item)
                    if sub_found:
                        found.extend(sub_keys)
        return bool(found), found

    @staticmethod
    def filter_attributes(
        raw_attrs: Dict[str, Any],
        include_extended: bool = False,
    ) -> Dict[str, Any]:
        """Filter process attributes against allowlist, dropping any unapproved keys."""
        allowed_keys = (
            EXTENDED_PROCESS_ATTRIBUTES
            if include_extended
            else ALLOWLISTED_PROCESS_ATTRIBUTES
        )
        filtered: Dict[str, Any] = {}
        for key, val in raw_attrs.items():
            if key in allowed_keys and key not in PROHIBITED_EXPORT_KEYS:
                filtered[key] = val

        # Validate mandatory process fields
        required = {"health_state", "cpu_time_ms", "resident_memory_bytes", "restart_count"}
        missing = [r for r in required if r not in filtered]
        if missing:
            raise ValueError(f"Missing required allowlisted process attributes: {missing}")

        if "exit_code" not in filtered:
            filtered["exit_code"] = None

        return filtered

    @staticmethod
    def filter_event(
        raw_event: Dict[str, Any],
        include_tenant: bool = False,
        include_extended: bool = False,
        objection_registry: Optional[SubjectObjectionRegistry] = None,
    ) -> Dict[str, Any]:
        """Produce clean, allowlisted export record from raw input, enforcing Art. 21 objection."""
        # Check person-level Article 21 objection
        actor_id = raw_event.get("actor_id") or raw_event.get("agent_id")
        reg = objection_registry or DEFAULT_OBJECTION_REGISTRY
        if actor_id and reg.is_opted_out(actor_id):
            raise SubjectObjectionError(str(actor_id))

        # Check and filter attributes
        raw_attrs = raw_event.get("attributes", {})
        if not isinstance(raw_attrs, dict):
            raise TypeError("attributes field must be an object")

        filtered_attrs = AllowlistFilter.filter_attributes(
            raw_attrs,
            include_extended=include_extended,
        )

        filtered_event: Dict[str, Any] = {}
        for key in ALLOWLISTED_ENVELOPE_FIELDS:
            if key == "attributes":
                filtered_event["attributes"] = filtered_attrs
            elif key == "tenant_id":
                if include_tenant and "tenant_id" in raw_event:
                    filtered_event["tenant_id"] = raw_event["tenant_id"]
            elif key in raw_event:
                filtered_event[key] = raw_event[key]

        # Enforce Zero-Customer-Payload pre-export gate
        tenant_id = raw_event.get("tenant_id")
        DEFAULT_VALIDATOR.validate_event(filtered_event, tenant_id=tenant_id)

        return filtered_event

    @staticmethod
    def filter_coding_agent_event(
        raw_event: Dict[str, Any],
        include_tenant: bool = True,
        objection_registry: Optional[SubjectObjectionRegistry] = None,
    ) -> Dict[str, Any]:
        """Produce clean, allowlisted, type-safe CodingAgentTelemetry export dictionary.

        Enforces zero-customer-payload boundary, GDPR Art. 21 objections, and fixed-arity tool counts.
        """
        # Check prohibited payload keys
        has_prohibited, prohibited_keys = AllowlistFilter.contains_prohibited_data(raw_event)
        if has_prohibited:
            raise ValueError(f"Prohibited payload keys detected in coding agent event: {prohibited_keys}")

        # Check person-level Article 21 objection
        actor_id = raw_event.get("actor_id") or raw_event.get("agent_id") or raw_event.get("host_id")
        reg = objection_registry or DEFAULT_OBJECTION_REGISTRY
        if actor_id and reg.is_opted_out(actor_id):
            raise SubjectObjectionError(str(actor_id))

        # Validate through strict CodingAgentTelemetry model
        event = CodingAgentTelemetry.from_dict(raw_event)
        event.validate()

        filtered: Dict[str, Any] = {
            "schema_version": event.schema_version,
            "harness": event.harness.value,
            "session_id": event.session_id,
            "timestamp": event.timestamp,
            "process": event.process.to_dict(),
            "kanban": event.kanban.to_dict(),
            "metrics": event.metrics.to_dict(),
            "network": event.network.to_dict(),
        }

        if event.observed_at is not None:
            filtered["observed_at"] = event.observed_at
        if include_tenant and event.tenant_id is not None:
            filtered["tenant_id"] = event.tenant_id
        if event.agent_id is not None:
            filtered["agent_id"] = event.agent_id
        if event.host_id is not None:
            filtered["host_id"] = event.host_id

        return filtered

    @staticmethod
    def validate_zero_payload(data: Any, tenant_id: Optional[str] = None) -> None:
        """Enforce strict Zero-Customer-Payload validation on arbitrary telemetry data."""
        validate_zero_customer_payload(data, tenant_id=tenant_id)


def filter_process_attributes(
    raw_attrs: Dict[str, Any],
    include_extended: bool = False,
) -> Dict[str, Any]:
    """Helper to filter process attributes."""
    return AllowlistFilter.filter_attributes(raw_attrs, include_extended=include_extended)


def sanitize_evidence_record(
    raw_event: Dict[str, Any],
    include_tenant: bool = False,
    objection_registry: Optional[SubjectObjectionRegistry] = None,
) -> Dict[str, Any]:
    """Helper to sanitize raw evidence record into strict allowlisted JSON object."""
    return AllowlistFilter.filter_event(
        raw_event,
        include_tenant=include_tenant,
        include_extended=False,
        objection_registry=objection_registry,
    )


def filter_coding_agent_telemetry(
    raw_event: Dict[str, Any],
    include_tenant: bool = True,
    objection_registry: Optional[SubjectObjectionRegistry] = None,
) -> Dict[str, Any]:
    """Helper to sanitize and validate raw coding agent telemetry."""
    return AllowlistFilter.filter_coding_agent_event(
        raw_event,
        include_tenant=include_tenant,
        objection_registry=objection_registry,
    )
