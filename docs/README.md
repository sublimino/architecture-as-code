# Documentation index

This page is the entry point for all repository documentation. Read this document first.
It describes the platform, explains how to run the services, and shows how to debug failures.

Two files sit at the repository root:

| File | Audience | Read it for |
| :--- | :--- | :--- |
| [`../README.md`](../README.md) | Human, new to OSRAMP | Platform overview and verification goals |
| [`../AGENTS.md`](../AGENTS.md) | Agent or engineer needing commands | Slice architecture, lifecycle targets, and shared pitfalls |

## Glossary

Use these defined terms. Do not use synonyms. Rule 1.11 of STE-Code forbids multiple names for one item.

| Term | Meaning |
| :--- | :--- |
| **slice** | One D2 delivery boundary, such as `d2-signalloom/`. A slice owns its namespaces, images, tests, and lifecycle. |
| **foundation** | The shared platform substrate: Kind cluster, Zot registry, signing keys, and Flux. `make up` creates it. |
| **lane** | One GCP environment: `demo-1`, `demo-2`, `ci-1`, or `ci-2`. Each lane contains one VM, one tailnet node, and one hand-off file. |
| **estate** | The software stack deployed to a lane VM. `make gcp-tf-demo-up` builds it. The lane is the infrastructure; the estate is the workload. |
| **hand-off file** | `deploy/gcp/<lane>.handoff.json`. Terraform writes this file. Later commands read the lane identity from it. |
| **surface** | One of two communication paths: VM-local surface or Tailscale tailnet surface. A lane can pass on one and fail on the other. |

## How the documentation fits together

```mermaid
flowchart TB
  START(["You are here<br/>docs/README.md"])

  subgraph learn["1 · Learn what this is"]
    RM["../README.md<br/>OSRAMP, the maturity model,<br/>the ingestion flow"]
    AG["../AGENTS.md<br/>slices, lifecycle targets,<br/>shared pitfalls"]
  end

  subgraph runlocal["2 · Run it locally"]
    TEST["../TESTING.md<br/>test suites and how to run them"]
    HV["../HUMAN_VALIDATION.md<br/>human review evidence"]
    BACK["deploying-a-backend-service.md<br/>four layers that each break a page"]
  end

  subgraph rungcp["3 · Run it on GCP"]
    RB["gcp-demo/RUNBOOK.md<br/>zero to a browser, step by step"]
    OPS["gcp-demo/OPERATIONS.md<br/>the four lanes, the tooling,<br/>and the traps"]
    DEP["../deploy/gcp/README.md<br/>real inputs and the hand-off"]
    TF["../terraform/README.md<br/>the three Terraform roots"]
  end

  subgraph debug["4 · Debug it"]
    CD["cluster-debugging.md<br/>field notes, and probes<br/>that lie"]
    RW["resilient-waits.md<br/>the wait library"]
    INC["gcp-demo/INCIDENTS-2026-08.md<br/>five blockers and their causes"]
  end

  START --> learn --> runlocal
  learn --> rungcp
  runlocal --> debug
  rungcp --> debug
  RB --> OPS
  OPS --> INC

  classDef entry fill:#fff3e0,stroke:#e65100,color:#e65100;
  class START entry;
```

## 1 · Learn What This Is

| Document | What it covers |
| :--- | :--- |
| [`../README.md`](../README.md) | OSRAMP, the four-level maturity model, team ownership, ingestion flow, and demo commands |
| [`../AGENTS.md`](../AGENTS.md) | Shared foundation, eight slices, lifecycle targets, and recurring pitfalls |
| [`system-map/`](system-map/) | Interactive isometric map of platform services and communication paths |
| [`../terraform/CONTRACT.md`](../terraform/CONTRACT.md) | Invariants and contracts between Terraform roots |

## 2 · Run the Platform

Start locally. The local workflow requires Docker.

| Document | What it covers |
| :--- | :--- |
| [`../README.md#getting-started`](../README.md#getting-started) | Local quickstart: run `./scripts/setup.sh`, then run a `demo-*-up` target |
| [`../TESTING.md`](../TESTING.md) | Test suites and execution instructions |
| [`../HUMAN_VALIDATION.md`](../HUMAN_VALIDATION.md) | Human verification logs from browser reviews |
| [`deploying-a-backend-service.md`](deploying-a-backend-service.md) | Deployment checklist: four separate layers that can each break page routing |

Deploy to GCP after local testing. The GCP workflow incurs costs and requires cloud credentials.

| Document | What it covers |
| :--- | :--- |
| [`gcp-demo/RUNBOOK.md`](gcp-demo/RUNBOOK.md) | Operator runbook from empty cloud project to dashboard in browser |
| [`gcp-demo/OPERATIONS.md`](gcp-demo/OPERATIONS.md) | Four deployment lanes, health tools, and diagnostic traps |
| [`../deploy/gcp/README.md`](../deploy/gcp/README.md) | Project inputs, service account roles, and hand-off contracts |
| [`../terraform/README.md`](../terraform/README.md) | Architecture rationale for three separate Terraform roots |
| [`../terraform/RUNBOOK.md`](../terraform/RUNBOOK.md) | Step-by-step Terraform execution for `demo-1` |
| [`../scripts/ci/README.md`](../scripts/ci/README.md) | Legacy GCP CI runner pipeline on `signalloom-ci` |

## 3 · Debug the System

| Document | What it covers |
| :--- | :--- |
| [`cluster-debugging.md`](cluster-debugging.md) | Field debugging notes for local stack. Section 8 details misleading probes. |
| [`resilient-waits.md`](resilient-waits.md) | Wait helpers in `scripts/lib/wait.sh` and pitfalls of bare `sleep` commands |
| [`gcp-demo/OPERATIONS.md#traps`](gcp-demo/OPERATIONS.md#traps) | Commands that return incorrect status codes |
| [`gcp-demo/INCIDENTS-2026-08.md`](gcp-demo/INCIDENTS-2026-08.md) | Post-mortem reports and diagnostic measurements for five August 2026 incidents |
| [`local-lifecycle-errata.md`](local-lifecycle-errata.md) | Errata and fixes for local lifecycle scripts |

## Reference and History

These documents record engineering decisions and investigations. They do not contain procedures.

| Area | Location |
| :--- | :--- |
| Signal Loom design notes, audits, and proposals | [`signalloom/`](signalloom/) — 49 design and architecture records |
| Signal Loom onboarding preflight proof | [`signalloom/slon-p1-preflight-proof.md`](signalloom/slon-p1-preflight-proof.md) |
| Signal Loom Phase 1 Governor certification report | [`signalloom/slon-p1-governor-report.md`](signalloom/slon-p1-governor-report.md) |
| Signal Loom Phase 1 technical design & architecture | [`signalloom/slon-p1-technical-design.md`](signalloom/slon-p1-technical-design.md) |
| Signal Loom Phase 2 preflight verification proof | [`signalloom/slon-p2-preflight-proof.md`](signalloom/slon-p2-preflight-proof.md) |
| Signal Loom Phase 2-1 dual agent deployment evidence | [`signalloom/slon-p2-1-evidence.md`](signalloom/slon-p2-1-evidence.md) |
| Signal Loom Phase 2-1 technical design & workload architecture | [`signalloom/slon-p2-1-technical-design.md`](signalloom/slon-p2-1-technical-design.md) |
| Signal Loom Phase 2-2 dynamic Nono capability & signed audit evidence | [`signalloom/slon-p2-2-evidence.md`](signalloom/slon-p2-2-evidence.md) |
| Signal Loom Phase 2-2 technical design & signed audit architecture | [`signalloom/slon-p2-2-technical-design.md`](signalloom/slon-p2-2-technical-design.md) |
| Signal Loom Phase 2-3 dual agent claim evidence | [`signalloom/slon-p2-3-evidence.md`](signalloom/slon-p2-3-evidence.md) |
| Signal Loom Phase 2-3 technical design & comparative telemetry | [`signalloom/slon-p2-3-technical-design.md`](signalloom/slon-p2-3-technical-design.md) |
| Signal Loom Phase 2-3 comparative telemetry architecture | [`signalloom/slon-p2-3-comparative-telemetry-architecture.md`](signalloom/slon-p2-3-comparative-telemetry-architecture.md) |
| Signal Loom Phase 2-3 dual agent claim workflow | [`signalloom/slon-p2-3-dual-agent-claim-workflow.md`](signalloom/slon-p2-3-dual-agent-claim-workflow.md) |
| Signal Loom Phase 3 preflight verification proof | [`signalloom/slon-p3-preflight-proof.md`](signalloom/slon-p3-preflight-proof.md) |
| Signal Loom Phase 3 docs portal provenance & gap analysis | [`signalloom/slon-p3-docs-portal-provenance.md`](signalloom/slon-p3-docs-portal-provenance.md) |
| Signal Loom Phase 3 specification tightening | [`signalloom/slon-p3-spec-tightening.md`](signalloom/slon-p3-spec-tightening.md) |
| Signal Loom Phase 3 preflight verification record | [`signalloom/slon-p3-preflight-verification-record.md`](signalloom/slon-p3-preflight-verification-record.md) |
| Signal Loom Phase 3-1 documentation portal evidence | [`signalloom/slon-p3-1-evidence.md`](signalloom/slon-p3-1-evidence.md) |
| Terraform build notes, chunks F1 to K | [`../terraform/notes/README.md`](../terraform/notes/README.md) — index of historical notes |
| Terraform module reference | `../terraform/modules/*/README.md` |
| Policy as versioned code | [`policy-as-versioned-code/`](policy-as-versioned-code/) |
| Platform appraisal (mid-2026) | [`appraisal/`](appraisal/) |
| Agent trust proposal and completion audit | [`agent-trust-project-proposal.md`](agent-trust-project-proposal.md), [`agent-trust-completion-audit.md`](agent-trust-completion-audit.md) |
| Frequently asked questions | [`FAQ.md`](FAQ.md) |

Note: `MEMORY/WORK/` contains historical session records.
These files document previous work sessions and do not describe current repository state.

## Writing Conventions

Documentation in this repository follows STE-Code, an adaptation of ASD-STE100 for software documentation.
Apply these primary rules to all documentation updates:

1. Use one term for each item. Do not use synonyms.
2. Keep instruction sentences to 20 words or fewer.
3. Write instructions in the imperative mood.
4. Put conditions before instructions.
5. Use `WARNING` for risks of data loss or security exposure.
   Use `CAUTION` for risks of incorrect operation.
6. State the specific cause with every warning or caution.
7. Use British English (en_GB) spelling per project directive.
