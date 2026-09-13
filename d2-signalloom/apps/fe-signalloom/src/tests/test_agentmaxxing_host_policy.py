"""AMXO-P1-2 host-policy and privacy-boundary contract tests."""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from typing import Any

CURRENT_DIR = Path(__file__).resolve().parent
SRC_DIR = CURRENT_DIR.parent
SIGNALLOOM_DIR = CURRENT_DIR.parents[3]
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

from agentmaxxing_host_policy import (  # noqa: E402
    AttributableIdentity,
    HostPolicy,
    IntegrityState,
    ObservationState,
    classify_boundary,
    filter_host_telemetry,
    load_host_policy,
)

FIXTURES = SIGNALLOOM_DIR / "governance" / "fixtures"
SCHEMAS = SIGNALLOOM_DIR / "governance" / "schemas"
POLICY_FIXTURE = FIXTURES / "agentmaxxing-host-policy.v1.json"
RAW_TELEMETRY_FIXTURE = FIXTURES / "agentmaxxing-raw-telemetry.v1.json"
POLICY_SCHEMA = SCHEMAS / "agentmaxxing-host-policy.v1.json"
EXPORT_SCHEMA = SCHEMAS / "agentmaxxing-export.v1.json"


def _load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise TypeError(f"fixture must contain a JSON object: {path}")
    return value


def _assert_closed_objects(test: unittest.TestCase, node: Any, location: str = "$") -> None:
    if isinstance(node, dict):
        if node.get("type") == "object":
            test.assertIs(
                node.get("additionalProperties"),
                False,
                f"object schema at {location} must fail closed",
            )
        for key, value in node.items():
            _assert_closed_objects(test, value, f"{location}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            _assert_closed_objects(test, value, f"{location}[{index}]")


class AgentMaxxingHostPolicyTests(unittest.TestCase):
    def test_canonical_policy_fixture_validates(self) -> None:
        policy = load_host_policy(POLICY_FIXTURE)

        self.assertEqual(policy.nono.version, "0.73.0")
        self.assertEqual(policy.host.service_account, "agentmaxxing-sensor")
        self.assertEqual(policy.approval.approver, "Andrew Martin")
        self.assertEqual(policy.lifecycle.evidence_retention_days, 30)
        self.assertEqual(policy.lifecycle.deletion_deadline_days, 7)
        self.assertEqual(policy.hashing.max_file_size_bytes, 16 * 1024 * 1024)
        self.assertEqual(policy.hashing.max_files_per_window, 120)
        self.assertEqual(policy.hashing.max_bytes_per_window, 64 * 1024 * 1024)
        self.assertEqual(policy.hashing.window_seconds, 60)

    def test_policy_roots_and_destinations_are_exact(self) -> None:
        policy = load_host_policy(POLICY_FIXTURE)

        roots = [root.path for root in (*policy.readable_roots, *policy.writable_roots)]
        self.assertTrue(roots)
        self.assertEqual(len(roots), len(set(roots)))
        self.assertTrue(all(path.startswith("/") and "*" not in path for path in roots))
        self.assertTrue(all(destination.port == 443 for destination in policy.network_destinations))
        self.assertTrue(all("*" not in destination.dns_name for destination in policy.network_destinations))

    def test_descriptor_relative_rules_are_complete(self) -> None:
        policy = load_host_policy(POLICY_FIXTURE)

        self.assertEqual(policy.artifact_access.syscall, "openat2")
        self.assertEqual(
            set(policy.artifact_access.resolve_flags),
            {"RESOLVE_BENEATH", "RESOLVE_NO_SYMLINKS", "RESOLVE_NO_XDEV"},
        )
        self.assertTrue(policy.artifact_access.require_regular_file)
        self.assertEqual(policy.artifact_access.required_link_count, 1)
        self.assertTrue(policy.artifact_access.require_same_mount_id)
        self.assertTrue(policy.artifact_access.revalidate_after_hash)

    def test_policy_contains_no_placeholders(self) -> None:
        serialized = json.dumps(_load_json(POLICY_FIXTURE), sort_keys=True).lower()

        for placeholder in ("tbd", "todo", "pending", "placeholder", "example.invalid"):
            self.assertNotIn(placeholder, serialized)

    def test_policy_rejects_invalid_approval_timestamp(self) -> None:
        raw_policy = _load_json(POLICY_FIXTURE)
        raw_policy["approval"]["approved_at"] = "not-a-date"

        with self.assertRaises(ValueError):
            HostPolicy.model_validate(raw_policy)

    def test_policy_rejects_numeric_approval_timestamp(self) -> None:
        raw_policy = _load_json(POLICY_FIXTURE)
        raw_policy["approval"]["approved_at"] = 0

        with self.assertRaises(ValueError):
            HostPolicy.model_validate(raw_policy)

    def test_json_schemas_fail_closed_recursively(self) -> None:
        _assert_closed_objects(self, _load_json(POLICY_SCHEMA))
        _assert_closed_objects(self, _load_json(EXPORT_SCHEMA))

    def test_policy_schema_freezes_exact_roots_and_destinations(self) -> None:
        policy = _load_json(POLICY_FIXTURE)
        schema = _load_json(POLICY_SCHEMA)

        for field in ("readable_roots", "writable_roots", "network_destinations"):
            field_schema = schema["properties"][field]
            values = policy[field]
            self.assertEqual(field_schema["minItems"], len(values))
            self.assertEqual(field_schema["maxItems"], len(values))
            self.assertIs(field_schema["items"], False)
            for index, value in enumerate(values):
                frozen_properties = field_schema["prefixItems"][index]["allOf"][1]["properties"]
                for key, frozen_schema in frozen_properties.items():
                    self.assertEqual(frozen_schema["const"], value[key])

    def test_export_schema_requires_each_type_specific_field(self) -> None:
        schema = _load_json(EXPORT_SCHEMA)

        for definition in (
            "process_attributes",
            "artifact_attributes",
            "network_attributes",
            "limit_attributes",
        ):
            attribute_schema = schema["$defs"][definition]
            self.assertEqual(
                set(attribute_schema["required"]),
                set(attribute_schema["properties"]),
            )
        self.assertEqual(
            schema["$defs"]["artifact_attributes"]["properties"]["root_id"]["enum"],
            ["agent-work", "agent-output"],
        )

    def test_export_filter_is_deterministic_and_fail_closed(self) -> None:
        raw = _load_json(RAW_TELEMETRY_FIXTURE)
        identity = AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        )

        policy = load_host_policy(POLICY_FIXTURE)
        first = filter_host_telemetry(raw, identity, policy)
        second = filter_host_telemetry(dict(reversed(raw.items())), identity, policy)

        self.assertEqual(first, second)
        self.assertEqual(first["tenant_id"], identity.tenant_id)
        self.assertEqual(first["agent_id"], identity.agent_id)
        self.assertEqual(first["host_id"], identity.host_id)
        self.assertEqual(
            list(first),
            [
                "schema_version",
                "session_id",
                "sequence",
                "observed_at",
                "source",
                "evidence_type",
                "observation_state",
                "integrity_state",
                "tenant_id",
                "agent_id",
                "host_id",
                "attributes",
            ],
        )

        exported = json.dumps(first, sort_keys=True)
        for secret in raw["prohibited_test_values"]:
            self.assertNotIn(secret, exported)

    def test_export_filter_uses_type_specific_attribute_allowlist(self) -> None:
        raw = _load_json(RAW_TELEMETRY_FIXTURE)
        identity = AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        )

        exported = filter_host_telemetry(raw, identity, load_host_policy(POLICY_FIXTURE))

        self.assertEqual(
            set(exported["attributes"]),
            {"cpu_time_ms", "exit_code", "health_state", "resident_memory_bytes", "restart_count"},
        )

    def test_export_filter_rejects_missing_safe_fields(self) -> None:
        raw = _load_json(RAW_TELEMETRY_FIXTURE)
        del raw["observed_at"]
        identity = AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        )

        with self.assertRaisesRegex(ValueError, "observed_at"):
            filter_host_telemetry(raw, identity, load_host_policy(POLICY_FIXTURE))

    def test_export_filter_rejects_invalid_safe_values(self) -> None:
        raw = _load_json(RAW_TELEMETRY_FIXTURE)
        raw["source"] = "caller-selected-source"
        identity = AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        )

        with self.assertRaises(ValueError):
            filter_host_telemetry(raw, identity, load_host_policy(POLICY_FIXTURE))

    def test_policy_rejects_caller_added_root(self) -> None:
        raw_policy = _load_json(POLICY_FIXTURE)
        raw_policy["readable_roots"].append(
            {
                "root_id": "caller-root",
                "path": "/home/customer",
                "artifact_hashing": False,
            }
        )

        with self.assertRaisesRegex(ValueError, "exactly match"):
            HostPolicy.model_validate(raw_policy)

    def test_policy_rejects_caller_added_destination(self) -> None:
        raw_policy = _load_json(POLICY_FIXTURE)
        raw_policy["network_destinations"].append(
            {
                "destination_id": "caller-destination",
                "dns_name": "evil.example.com",
                "transport": "tcp",
                "port": 443,
                "tls_required": True,
            }
        )

        with self.assertRaisesRegex(ValueError, "exactly match"):
            HostPolicy.model_validate(raw_policy)

    def test_export_filter_rejects_unregistered_identity(self) -> None:
        raw = _load_json(RAW_TELEMETRY_FIXTURE)
        identity = AttributableIdentity(
            tenant_id="other-tenant",
            agent_id="other-agent",
            host_id="other-host",
        )

        with self.assertRaisesRegex(ValueError, "frozen registration"):
            filter_host_telemetry(raw, identity, load_host_policy(POLICY_FIXTURE))

    def test_export_filter_rejects_artifact_from_nonhashable_root(self) -> None:
        raw = _load_json(RAW_TELEMETRY_FIXTURE)
        raw.update(
            {
                "evidence_type": "artifact",
                "attributes": {
                    "artifact_id": "hmac-sha256:" + "a" * 64,
                    "root_id": "customer-input",
                    "sha256": "b" * 64,
                    "size_bytes": 12,
                    "mtime_ns": 1,
                },
            }
        )
        identity = AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        )

        with self.assertRaisesRegex(ValueError, "not approved for hashing"):
            filter_host_telemetry(raw, identity, load_host_policy(POLICY_FIXTURE))

    def test_collection_limit_must_be_unobserved(self) -> None:
        raw = _load_json(RAW_TELEMETRY_FIXTURE)
        raw.update(
            {
                "evidence_type": "collection-limit",
                "observation_state": "observed",
                "attributes": {
                    "reason_code": "oversize",
                    "max_file_size_bytes": 16777216,
                    "max_files_per_window": 120,
                    "max_bytes_per_window": 67108864,
                    "window_seconds": 60,
                },
            }
        )
        identity = AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        )

        with self.assertRaisesRegex(ValueError, "must be unobserved"):
            filter_host_telemetry(raw, identity, load_host_policy(POLICY_FIXTURE))

    def test_export_filter_rejects_invalid_timestamp(self) -> None:
        raw = _load_json(RAW_TELEMETRY_FIXTURE)
        raw["observed_at"] = "not-a-date"
        identity = AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        )

        with self.assertRaises(ValueError):
            filter_host_telemetry(raw, identity, load_host_policy(POLICY_FIXTURE))

    def test_export_filter_rejects_numeric_timestamp(self) -> None:
        raw = _load_json(RAW_TELEMETRY_FIXTURE)
        raw["observed_at"] = 0
        identity = AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        )

        with self.assertRaises(ValueError):
            filter_host_telemetry(raw, identity, load_host_policy(POLICY_FIXTURE))

    def test_boundary_states_do_not_imply_each_other(self) -> None:
        absent = classify_boundary(integrity_verified=True)
        denied = classify_boundary(denied=True)
        observed = classify_boundary(observed=True)

        self.assertEqual(absent.observation_state, ObservationState.UNOBSERVED)
        self.assertEqual(absent.integrity_state, IntegrityState.VERIFIED)
        self.assertEqual(denied.observation_state, ObservationState.DENIED)
        self.assertEqual(denied.integrity_state, IntegrityState.NOT_VERIFIED)
        self.assertEqual(observed.observation_state, ObservationState.OBSERVED)

    def test_boundary_rejects_contradictory_observation(self) -> None:
        with self.assertRaisesRegex(ValueError, "both observed and denied"):
            classify_boundary(observed=True, denied=True)


if __name__ == "__main__":
    unittest.main()
