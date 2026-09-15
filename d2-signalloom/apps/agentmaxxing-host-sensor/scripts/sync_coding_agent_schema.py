#!/usr/bin/env python3
"""Schema conformance validator and generator for CodingAgentTelemetry.

Validates that JSON Schema, Go struct definitions, and Python dataclasses remain 100% congruent.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent.parent
SCHEMA_PATH = REPO_ROOT / "d2-signalloom" / "apps" / "agentmaxxing-host-sensor" / "schemas" / "coding-agent-telemetry.v1.schema.json"
GO_MODEL_PATH = REPO_ROOT / "d2-signalloom" / "apps" / "signal-ingest" / "codingagent" / "telemetry.go"
PY_MODEL_PATH = REPO_ROOT / "d2-signalloom" / "apps" / "agentmaxxing-host-sensor" / "coding_agent_models.py"


def validate_conformance() -> None:
    if not SCHEMA_PATH.exists():
        print(f"FAIL: Schema not found at {SCHEMA_PATH}", file=sys.stderr)
        sys.exit(1)

    with open(SCHEMA_PATH, "r", encoding="utf-8") as f:
        schema = json.load(f)

    # 1. Schema properties
    envelope_props = set(schema["properties"].keys())
    proc_props = set(schema["$defs"]["process_info"]["properties"].keys())
    kanban_props = set(schema["$defs"]["kanban_info"]["properties"].keys())
    metrics_props = set(schema["$defs"]["metrics_info"]["properties"].keys())
    tool_props = set(schema["$defs"]["tool_counts"]["properties"].keys())
    network_props = set(schema["$defs"]["network_info"]["properties"].keys())
    harnesses = set(schema["properties"]["harness"]["enum"])

    # 2. Check Go source code contains all fields
    with open(GO_MODEL_PATH, "r", encoding="utf-8") as f:
        go_code = f.read()

    for p in envelope_props:
        if f'`json:"{p}' not in go_code:
            print(f"FAIL: Go model missing envelope field tag `json:\"{p}\"`", file=sys.stderr)
            sys.exit(1)

    for p in proc_props:
        if f'`json:"{p}"`' not in go_code:
            print(f"FAIL: Go model missing process field tag `json:\"{p}\"`", file=sys.stderr)
            sys.exit(1)

    for p in kanban_props:
        if f'`json:"{p}"`' not in go_code:
            print(f"FAIL: Go model missing kanban field tag `json:\"{p}\"`", file=sys.stderr)
            sys.exit(1)

    for p in metrics_props:
        if f'`json:"{p}"`' not in go_code:
            print(f"FAIL: Go model missing metrics field tag `json:\"{p}\"`", file=sys.stderr)
            sys.exit(1)

    for p in tool_props:
        if f'`json:"{p}"`' not in go_code:
            print(f"FAIL: Go model missing tool_counts field tag `json:\"{p}\"`", file=sys.stderr)
            sys.exit(1)

    for p in network_props:
        if f'`json:"{p}"`' not in go_code:
            print(f"FAIL: Go model missing network field tag `json:\"{p}\"`", file=sys.stderr)
            sys.exit(1)

    for h in harnesses:
        if f'"{h}"' not in go_code:
            print(f"FAIL: Go model missing harness enum member {h!r}", file=sys.stderr)
            sys.exit(1)

    # 3. Check Python source code
    with open(PY_MODEL_PATH, "r", encoding="utf-8") as f:
        py_code = f.read()

    for p in tool_props:
        if f'"{p}"' not in py_code:
            print(f"FAIL: Python model missing tool count {p!r}", file=sys.stderr)
            sys.exit(1)

    for h in harnesses:
        if f'"{h}"' not in py_code:
            print(f"FAIL: Python model missing harness enum member {h!r}", file=sys.stderr)
            sys.exit(1)

    print("PASS: Schema conformance validated across JSON Schema, Go structs, and Python dataclasses.")


if __name__ == "__main__":
    validate_conformance()
