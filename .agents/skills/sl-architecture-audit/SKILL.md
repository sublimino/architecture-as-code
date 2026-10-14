---
name: sl-architecture-audit
description: "Read-only architecture conformance and traceability audit using bounded offline repository gates. USE WHEN architecture audit, architecture conformance, traceability, Flux coverage, diagram vocabulary, or registered-test coverage."
---

# sl-architecture-audit

Collect deterministic repository evidence before interpreting architecture
claims. This skill reports conformance and traceability findings.
It leaves seam design, refactoring, tickets, and remediation to `sl-drift-sweep` Axis C.

## Public CLI

```bash
.agents/skills/sl-architecture-audit/Tools/architecture-audit.sh \
  --repo-root /path/to/osramp-demo \
  --timeout 120
```

The collector prints one JSON object to stdout. Findings still exit zero.
Usage and instrument failures exit nonzero without emitting partial JSON.
Raw command output remains in the mode-0700 run directory named on safe stderr
diagnostics.

## Boundaries

- Default evidence is static and offline.
- Never install tools, build browser assets, query clusters, mutate resources,
  auto-fix findings, rewrite templates, or invoke `make -n`.
- Run only `docs-lint`, `test-alignment`, `flux-coverage`, and
  `test/diagram-focus.bats`.
- Diagram vocabulary is not graph-edge or trust-boundary proof.
- `topology_edges` therefore remains required `UNVERIFIED` with
  `coverage_gap` until a separately approved topology instrument exists.
- Explicit registrations are facts. Never infer complete graph coverage.

Follow [`Workflows/Audit.md`](Workflows/Audit.md) when interpreting evidence.
