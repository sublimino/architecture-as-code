# Reference: The Signal Loom Offline Test Pyramid

The Signal Loom platform defines a four-tier test pyramid designed to catch regressions without spinning up Kubernetes or external cloud dependencies.

```
       ▲
      / \     E2E / Browser Acceptance (Playwright, 7s)
     /   \    -----------------------------------------
    /     \   Contract & Sensor Suites (Python, BATS, Go, 15s)
   /       \  ------------------------------------------------
  /         \ Vitest Component & Weave Unit Tests (Bun, 2s)
 /           \ ---------------------------------------------------
/             \ Docs Lint, Schema Sync & Static Analysis (0.5s)
```

## Layer Breakdown

| Layer | Runner / Tool | Target / Command | Invariant Asserts |
|---|---|---|---|
| **L1: Static & Docs** | `make docs-lint` | `scripts/docs-lint.sh` | Zero dead links, valid diagram paths, clean headings, zero em-dashes in bootstrap SQL |
| **L2: Schema Sync** | Python / SQL diff | `generate-bootstrap.py` | `discovery-portal-bootstrap.sql` equals output of `001` through latest migrations |
| **L3: Frontend Unit** | `bun run test` | `apps/dashboard-signalloom` | 162+ Vitest specs (Weave, Signals, Risk gauges, Telemetry) |
| **L4: Host Sensor** | `python3 unittest` | `apps/agentmaxxing-host-sensor` | Procfs / netlink attribution, Landlock filesystem containment |
| **L5: Go Controllers** | `go test ./...` | `apps/fleet-manager/`, `pkg/` | Multi-plane DAG state transitions, cascade containment logic |
| **L6: Full Offline** | `make test-all-offline` | Root Makefile | Full battery without cluster |
