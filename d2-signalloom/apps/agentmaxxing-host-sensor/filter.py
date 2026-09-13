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
    "host_id",
    "attributes",
    "tenant_id",
}

# Forbidden keys that must NEVER appear in exported evidence records
PROHIBITED_EXPORT_KEYS: Set[str] = {
    "raw_nono_record",
    "command",
    "cmdline",
    "argv",
    "path",
    "url",
    "error",
    "file_contents",
    "memory_contents",
    "streamed_payload_digest",
    "streamed_payload_contents",
    "network_payload_contents",
    "env",
    "environ",
    "stack",
    "heap",
    "registers",
    "payload",
    "stdin",
    "stdout",
    "stderr",
}


class AllowlistFilter:
    """Enforces strict field allowlisting and zero-payload isolation on telemetry records."""

    @staticmethod
    def contains_prohibited_data(data: Any) -> Tuple[bool, List[str]]:
        """Check if dictionary or object contains prohibited keys at any nesting level."""
        found: List[str] = []
        if isinstance(data, dict):
            for key, val in data.items():
                if key in PROHIBITED_EXPORT_KEYS or "secret" in str(key).lower():
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
    ) -> Dict[str, Any]:
        """Produce clean, allowlisted export record from raw input."""
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

        return filtered_event


def filter_process_attributes(
    raw_attrs: Dict[str, Any],
    include_extended: bool = False,
) -> Dict[str, Any]:
    """Helper to filter process attributes."""
    return AllowlistFilter.filter_attributes(raw_attrs, include_extended=include_extended)


def sanitize_evidence_record(
    raw_event: Dict[str, Any],
    include_tenant: bool = False,
) -> Dict[str, Any]:
    """Helper to sanitize raw evidence record into strict allowlisted JSON object."""
    return AllowlistFilter.filter_event(raw_event, include_tenant=include_tenant, include_extended=False)
