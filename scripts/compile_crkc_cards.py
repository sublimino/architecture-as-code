#!/usr/bin/env python3
import json
import subprocess
import os
import sys

PROPOSAL = "/home/andy/Documents/Obsidian/v1/2. Areas/CEO/Innovation Proposals/Proposal — Signal Loom Runtime Confinement, Live FAIR Risk & Kernel Containment (2026-Q3).md"
REPO = "/home/andy/src/cp/osramp-demo"
INTEGRATION = "integration/crkc-v0.1.0"
SHORTCODE = "CRKC"
KANBAN_CHECK = f"{REPO}/scripts/kanban-check.sh"

FLOORS = {
    "S": {"words": 250, "lines": 20, "deliv": 4, "tests": 3},
    "M": {"words": 450, "lines": 35, "deliv": 5, "tests": 4},
    "L": {"words": 700, "lines": 50, "deliv": 6, "tests": 5},
    "Deep": {"words": 1000, "lines": 70, "deliv": 7, "tests": 5},
}

def verify_spec(spec, band, role):
    body = "\n".join(
        str(spec.get(key) or "") if not isinstance(spec.get(key), list)
        else "\n".join(str(item) for item in spec.get(key) or [])
        for key in ("objective", "approach", "deliverables", "testSurface",
                    "evidence", "failureModes", "outOfScope")
    )
    lines = [ln.strip() for ln in body.splitlines() if ln.strip()]
    distinct = len({ln for ln in lines if len(ln) > 12})
    substantive = [ln for ln in lines if len(ln) > 12]
    metrics = {
        "words": len(body.split()),
        "lines": len(lines),
        "deliverables": len(spec.get("deliverables") or []),
        "tests": len(spec.get("testSurface") or []),
        "distinctLineRatio": round(distinct / len(substantive), 3) if substantive else 0.0,
        "chars": len(body),
    }
    floor = FLOORS[band]
    req_tests = 0 if role in ("governor", "preflight") else floor["tests"]
    
    ok = (
        metrics["words"] >= floor["words"] and
        metrics["lines"] >= floor["lines"] and
        metrics["deliverables"] >= floor["deliv"] and
        metrics["tests"] >= req_tests
    )
    return ok, metrics, floor

def run_create(card):
    logical_id = card["logical_id"]
    role = card["role"]
    title = card["title"]
    size = card["size"]
    agent = card["agent"]
    deps = card.get("depends_on", [])
    deep_rationale = card.get("deep_rationale")
    spec = card["spec"]
    
    ok, metrics, floor = verify_spec(spec, size, role)
    if not ok:
        print(f"FAILED metric check for {logical_id}: {metrics} vs {floor}", file=sys.stderr)
        sys.exit(1)
    
    spec_path = f"/tmp/crkc-{logical_id.lower()}.spec.json"
    with open(spec_path, "w") as f:
        json.dump(spec, f, indent=2)
    
    cmd = [
        KANBAN_CHECK, "create",
        "--repo", REPO,
        "--shortcode", SHORTCODE,
        "--logical-id", logical_id,
        "--role", role,
        "--title", f"CRKC-{logical_id}: {title}",
        "--proposal", PROPOSAL,
        "--integration", INTEGRATION,
        "--size", size,
        "--agent", agent,
        "--spec-file", spec_path,
        "--apply"
    ]
    for d in deps:
        cmd.extend(["--depends-on", d])
    if deep_rationale:
        cmd.extend(["--deep-rationale", deep_rationale])
        
    print(f"Creating card {logical_id} ({size}, {agent})...")
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"ERROR creating {logical_id}:\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}", file=sys.stderr)
        sys.exit(res.returncode)
    else:
        print(f"SUCCESS {logical_id}: {res.stdout.strip()}")
