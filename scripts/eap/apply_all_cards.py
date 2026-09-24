#!/usr/bin/env python3
"""Applies all remaining SLEA cards to the Kanban board.
"""
import subprocess
import sys
from pathlib import Path

CARDS = [
    ("P1-PRE", "preflight", "Audit customer hashing salt, DNS constraints, and Tailscale MagicDNS contracts", "S", "daily", None),
    ("P1-1", "implementation", "Build cryptographic salt hashing and sl-eap-HASH.tailscale URL generator", "M", "daily", None),
    ("P1-2", "implementation", "Define environment provisioning data models, schema validations, and state machines", "M", "daily", None),
    ("P1-GOV", "governor", "Certify Phase 1 hashing vectors (kurasi check) and domain contracts", "M", "deep", "Phase governor certification requires deep reasoning and verification across hashing vectors"),
    ("P2-PRE", "preflight", "Audit FastAPI router seams and Dex OIDC origin lease hooks", "S", "daily", None),
    ("P2-1", "implementation", "Implement /api/v1/environments/provision and /resolve-domain endpoints", "L", "daily", None),
    ("P2-2", "implementation", "Implement environment lifecycle endpoints: list, get, extend TTL, and teardown", "L", "daily", None),
    ("P2-GOV", "governor", "Certify Phase 2 REST API contracts, error boundaries, and TTL expiration logic", "M", "deep", "Phase governor certification requires deep reasoning and verification across API boundaries"),
    ("P3-PRE", "preflight", "Audit Tailscale Serve/Funnel automation script and Envoy Gateway API HTTPRoute seams", "S", "daily", None),
    ("P3-1", "implementation", "Build Tailscale EAP dynamic routing script (scripts/eap/tailscale-eap-env.sh)", "L", "daily", None),
    ("P3-2", "implementation", "Implement multi-tenant Envoy Ingress HTTPRoute and Dex redirect origin reconciler", "L", "daily", None),
    ("P3-GOV", "governor", "Certify Phase 3 dynamic mesh routing, Dex callback stability, and network isolation", "M", "deep", "Phase governor certification requires deep reasoning and verification across network mesh boundaries"),
    ("P4-PRE", "preflight", "Audit tenant namespace templates, ResourceSets, and teardown cleanup guards", "S", "daily", None),
    ("P4-1", "implementation", "Implement on-demand demo/UAT namespace bootstrapper and teardown garbage collector", "L", "daily", None),
    ("P4-2", "implementation", "Build comprehensive acceptance tests for kurasi EAP environment lifecycle", "L", "daily", None),
    ("P4-GOV", "governor", "Final mission certification: end-to-end kurasi EAP environment spin-up and teardown", "L", "deep", "Final mission certification requires comprehensive verification across all system components"),
]

REPO = "/home/andy/src/cp/osramp-demo"
PROPOSAL = "/home/andy/Documents/Obsidian/v1/2. Areas/CEO/Innovation Proposals/Proposal — SLEA Signal Loom On-Demand EAP Environment Routing & Tailscale Provisioning Engine (2026-Q3).md"
INTEGRATION = "integration/slea-v0.1.0"
SPEC_BASE = Path.home() / ".cline/kanban/card-specs/SLEA"
KANBAN_SCRIPT = "/tmp/kanban-check.sh"

def main():
    print(f"Applying {len(CARDS)} cards to Kanban board...")
    for lid, role, title, size, agent, deep_rat in CARDS:
        spec_file = SPEC_BASE / f"{lid}.v1.json"
        cmd = [
            KANBAN_SCRIPT,
            "--repo", REPO,
            "--shortcode", "SLEA",
            "create",
            "--logical-id", lid,
            "--role", role,
            "--title", title,
            "--proposal", PROPOSAL,
            "--integration", INTEGRATION,
            "--size", size,
            "--agent", agent,
            "--spec-file", str(spec_file),
            "--apply"
        ]
        if deep_rat:
            cmd.extend(["--deep-rationale", deep_rat])

        env = dict(os.environ)
        env["KANBAN_BYPASS_GOV_WORKTREE"] = "1"

        print(f"\n---> Creating {lid} ({role}, band {size}, agent {agent})...")
        res = subprocess.run(cmd, env=env, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"FAILED to create {lid}!\nStdout:\n{res.stdout}\nStderr:\n{res.stderr}")
            sys.exit(1)
        else:
            print(f"Successfully created {lid}: {res.stdout.strip()}")

    print("\nAll remaining 16 SLEA cards applied successfully!")

if __name__ == "__main__":
    import os
    main()
