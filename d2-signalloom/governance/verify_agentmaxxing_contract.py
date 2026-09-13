"""Validate the frozen AMXO-P1-2 JSON Schema contracts and negatives."""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, ValidationError

GOVERNANCE_DIR = Path(__file__).resolve().parent
SIGNALLOOM_DIR = GOVERNANCE_DIR.parent
SRC_DIR = SIGNALLOOM_DIR / "apps" / "fe-signalloom" / "src"
sys.path.insert(0, str(SRC_DIR))

from agentmaxxing_host_policy import (  # noqa: E402
    AttributableIdentity,
    filter_host_telemetry,
    load_host_policy,
)


def _load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_bytes())
    if type(value) is not dict:
        raise TypeError(f"contract artifact must contain a JSON object: {path}")
    return value


def _expect_rejected(
    validator: Draft202012Validator,
    instance: dict[str, Any],
    description: str,
) -> None:
    try:
        validator.validate(instance)
    except ValidationError:
        return
    raise AssertionError(f"schema accepted prohibited {description}")


def main() -> None:
    fixtures = GOVERNANCE_DIR / "fixtures"
    schemas = GOVERNANCE_DIR / "schemas"
    policy_path = fixtures / "agentmaxxing-host-policy.v1.json"
    policy_instance = _load(policy_path)
    raw_record = _load(fixtures / "agentmaxxing-raw-telemetry.v1.json")
    policy_schema = _load(schemas / "agentmaxxing-host-policy.v1.json")
    export_schema = _load(schemas / "agentmaxxing-export.v1.json")

    Draft202012Validator.check_schema(policy_schema)
    Draft202012Validator.check_schema(export_schema)
    policy_validator = Draft202012Validator(
        policy_schema,
        format_checker=Draft202012Validator.FORMAT_CHECKER,
    )
    export_validator = Draft202012Validator(
        export_schema,
        format_checker=Draft202012Validator.FORMAT_CHECKER,
    )
    policy_validator.validate(policy_instance)

    policy = load_host_policy(policy_path)
    exported = filter_host_telemetry(
        raw_record,
        AttributableIdentity(
            tenant_id="tenant-agentmaxxing",
            agent_id="agentmaxxing-linux-001",
            host_id="amx-host-001",
        ),
        policy,
    )
    export_validator.validate(exported)

    added_root = copy.deepcopy(policy_instance)
    added_root["readable_roots"].append(
        {"root_id": "evil", "path": "/home/customer", "artifact_hashing": False}
    )
    _expect_rejected(policy_validator, added_root, "caller-added root")

    extra_export = copy.deepcopy(exported)
    extra_export["command"] = "forbidden"
    _expect_rejected(export_validator, extra_export, "extra export field")

    partial_attributes = copy.deepcopy(exported)
    del partial_attributes["attributes"]["health_state"]
    _expect_rejected(export_validator, partial_attributes, "partial attributes")

    print("draft-2020-12 schemas: PASS")
    print("canonical policy instance: PASS")
    print("allowlisted export instance: PASS")
    print("added-root/extra-field/partial-attributes negatives: PASS")


if __name__ == "__main__":
    main()
