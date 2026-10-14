#!/usr/bin/env python3
"""Build the fixed architecture-audit report from private TSV observations."""

import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        return 2

    checks = []
    with open(sys.argv[1], encoding="utf-8") as stream:
        for raw in stream:
            fields = raw.rstrip("\n").split("\t")
            if len(fields) != 7:
                return 2
            check_id, status, exit_text, required, kind, reason, metric = fields
            metric_name, metric_text = metric.split("=", 1)
            checks.append(
                {
                    "id": check_id,
                    "status": status,
                    "exit_code": None if exit_text == "null" else int(exit_text),
                    "required": required == "true",
                    "evidence_kind": kind,
                    "reason_code": reason,
                    "metrics": {metric_name: int(metric_text)},
                }
            )

    report = {
        "schema_version": 1,
        "skill": "sl-architecture-audit",
        "checks": checks,
    }
    json.dump(report, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
