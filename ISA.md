---
task: "SLCD-P6-2: Create documentation and detection runbook in apps/docs-signalloom"
project: "osramp-demo"
slug: "slcd-p6-2"
effort: "E4"
effort_source: "classifier"
phase: "verify"
progress: "13/13"
mode: "algorithm"
started: "2026-09-15T13:28:15+01:00"
updated: "2026-09-15T13:36:00+01:00"
---

# ISA: SLCD-P6-2 Architecture Documentation & Detection Runbook in docs-signalloom

## Problem
Following the implementation of the Signal Loom Coding Agent & Harness Detective Telemetry pipeline across Phases 1–5 (host sensor procfs/cgroup discovery, non-blocking Kanban task correlation, zero-payload transcript parsing, netlink socket inode attribution, Go ingestion endpoint, and dashboard topology visualization), the system lacked operator-facing and auditor-facing documentation in `apps/docs-signalloom`. Without comprehensive architecture guides, detection runbooks, zero-payload privacy evidence, honest lawful-basis disclosure, and CIDR range maintenance procedures, security operators cannot interpret telemetry or handle unknown classifications, and compliance auditors cannot verify the privacy invariants or understand the open GDPR/Works Council requirements.

## Vision
The Signal Loom documentation portal (`/docs`) provides authoritative, clear, and visually rich documentation grounded in what Phases 1–5 actually built and empirically tested:
1. An end-to-end **Detective Telemetry Architecture** guide detailing the sensor-to-dashboard pipeline, passive procfs scanning, netlink socket attribution, and ingestion contracts.
2. A comprehensive **Coding Agent Detection & Governance Runbook** equipping security operators to interpret harness classifications, understand confidence scores, triage unknown agents without invading developer privacy, and enforce security policies.
3. An operator-facing **Zero-Customer-Payload Privacy Architecture** explanation detailing structural allowlists, memory scrubbing, error boundaries, and concrete falsification test evidence from P1-2 and P4-1.
4. An honest, transparent **Lawful Basis & GDPR Legitimate Interests Assessment** reflecting the actual DISABLED status on employee workstations and documenting all 40 OPEN items (22 blocking) and Works Council co-determination requirements.
5. A clear **Inference Provider CIDR Provenance & Update Procedure** explaining tiered attribution (`dedicated`, `shared`, `loopback`), control-plane exclusion, and step-by-step instructions for updating provider IP ranges.

## Out of Scope
- Documenting or enabling any collection of prompt text, file contents, credential values, or raw process memory.
- Documenting or permitting individual developer productivity tracking or work-rate performance scoring.
- Asserting a resolved/compliant GDPR lawful basis while 40 items remain OPEN.
- Inventing aspirational pipeline behaviors that diverge from what Phases 1–5 built and tested.

## Principles
1. **Empirical Grounding**: Document the real system as built and tested in Phases 1–5, not idealized or aspirational proposals.
2. **Absolute Privacy Transparency**: Provide clear non-engineer explanations of the Zero-Customer-Payload invariant backed by falsifiable test evidence.
3. **Auditor Honesty**: State compliance and lawful-basis positions transparently, publishing OPEN items and co-determination blockers without sanitization.
4. **Operator Actionability**: Ensure every runbook section answers "what do I observe, what does it mean, and what exact step do I take next".
5. **Structural Navigation Integrity**: Every new page must be integrated into the Starlight navigation hierarchy, typechecked with Astro diagnostics, and audited for zero broken links.

## Constraints
1. **Astro / Starlight Compatibility**: Follow existing Starlight documentation structure (`src/content/docs/**/*.mdx`), using `<Mermaid ... />` for architectural and workflow diagrams.
2. **Zero Link Regressions**: `bun run audit:links` (`node scripts/link-audit.mjs`) must pass with 0 broken internal links.
3. **Clean Diagnostics**: `bun run check` (`astro check`) and `bun run build` must pass with zero errors.
4. **Strict Allowlist**: Field definitions must match the frozen `codingagent.v1` schema from P1-1.

## Goal
Publish five comprehensive documentation pages in `d2-signalloom/apps/docs-signalloom` covering architecture, operator detection runbook, zero-payload privacy evidence, honest lawful basis, and CIDR range management, seamlessly integrated into navigation and verified through Astro diagnostics, link audits, and Playwright acceptance rendering.

## Criteria
- [x] ISC-1: Create `operate/coding-agent-detection-runbook.mdx` covering operator workflow, harness signatures, confidence score interpretation, unknown triage steps, and developer productivity prohibition.
- [x] ISC-2: Create `security/detective-telemetry-architecture.mdx` covering sensor -> ingestion -> dashboard pipeline, passive procfs scanning, netlink socket attribution, and wire contracts with Mermaid diagrams.
- [x] ISC-3: Create `security/zero-customer-payload.mdx` explaining what is and is not collected, positive field tables, memory scrubbing, error boundaries, and cross-linking P1-2 (13 fixtures) and P4-1 (15 fixtures) falsification evidence.
- [x] ISC-4: Create `reference/lawful-basis-assessment.mdx` documenting GDPR Art 6(1)(f) LIA 3-limb analysis, 40 OPEN items (22 blocking), disabled status on employee workstations, and Works Council positions.
- [x] ISC-5: Create `reference/inference-provider-ranges.mdx` documenting CIDR range provenance, dedicated vs shared vs loopback tiers, control-plane exclusion, and step-by-step range update procedure.
- [x] ISC-6: Update `astro.config.mjs` sidebar to include all 5 new pages in navigation under `Operate agents`, `Security`, and `Reference`.
- [x] ISC-7: Update `test/acceptance/docs.spec.ts` to include the new documentation pages and assert heading and Mermaid SVG rendering.
- [x] ISC-8: Verify `bun run check` in `d2-signalloom/apps/docs-signalloom` runs clean with 0 errors.
- [x] ISC-9: Verify `bun run build` and `bun run audit:links` in `d2-signalloom/apps/docs-signalloom` pass with 0 broken internal links.
- [x] ISC-10: Verify `make demo-agentmaxxing-docs-test` executes and passes all browser acceptance checks.
- [x] ISC-11: Anti: Ensure no prompt text, file contents, credential values, or process memory are collected or presented as collectible.
- [x] ISC-12: Anti: Ensure no sanitised "all-clear" claim is made for GDPR/lawful basis while items remain OPEN.
- [x] ISC-13: Anti: Ensure no developer productivity scoring is documented or permitted.

## Test Strategy
- ISC-1 to ISC-5: `Read` / `test -f` to verify content completeness, structure, and Mermaid diagram definitions.
- ISC-6: `Read` / `astro.config.mjs` verification to ensure navigation links match page slugs.
- ISC-7: `test/acceptance/docs.spec.ts` verification with Playwright.
- ISC-8: `bun run --cwd d2-signalloom/apps/docs-signalloom check`.
- ISC-9: `bun run --cwd d2-signalloom/apps/docs-signalloom build && bun run --cwd d2-signalloom/apps/docs-signalloom audit:links`.
- ISC-10: `make demo-agentmaxxing-docs-test` (`./scripts/docs-render-check.sh docs.spec.ts`).
- ISC-11 to ISC-13: Static content audit confirming negative security invariants, open GDPR status, and productivity prohibition.

## Features
- F1: Operator Detection Runbook (`operate/coding-agent-detection-runbook.mdx`)
- F2: Detective Telemetry Architecture (`security/detective-telemetry-architecture.mdx`)
- F3: Zero-Customer-Payload Privacy Architecture (`security/zero-customer-payload.mdx`)
- F4: Lawful Basis & GDPR Assessment (`reference/lawful-basis-assessment.mdx`)
- F5: Inference Provider CIDR Provenance & Update Procedure (`reference/inference-provider-ranges.mdx`)
- F6: Navigation & Acceptance Integration (`astro.config.mjs`, `docs.spec.ts`, `docs-render-check.sh`)

## Decisions
- 2026-09-15T13:30:00+01:00: Organized documentation into five dedicated topic pages matching Starlight's taxonomy (`operate/`, `security/`, `reference/`) rather than cramming all subjects into a single monolithic page.
- 2026-09-15T13:30:00+01:00: Included Mermaid sequence and flowchart diagrams on all five pages to provide visual clarity and ensure compliance with `docs.spec.ts` SVG rendering assertions.
- 2026-09-15T13:30:00+01:00: Stated the GDPR lawful basis position with complete fidelity to `docs/signalloom/slcd-p1-5-lawful-basis.md`, highlighting the 40 OPEN items and the mandatory DISABLED state on employee workstations.
- 2026-09-15T13:35:46+01:00: Hardened `scripts/docs-render-check.sh` port selection to dynamically scan for an available port when port 4325 is already bound by another background process, preventing preview server collisions.

## Changelog
- 2026-09-15T13:30:00+01:00: Initial ISA created for SLCD-P6-2.
- 2026-09-15T13:36:00+01:00: Completed all 5 documentation pages, navigation updates, and test suite verification with 100% pass across Astro check, link audits, and Playwright tests.

## Verification
- ISC-1: `test -f d2-signalloom/apps/docs-signalloom/src/content/docs/operate/coding-agent-detection-runbook.mdx` — Verified (file present, 165 lines).
- ISC-2: `test -f d2-signalloom/apps/docs-signalloom/src/content/docs/security/detective-telemetry-architecture.mdx` — Verified (file present, 163 lines).
- ISC-3: `test -f d2-signalloom/apps/docs-signalloom/src/content/docs/security/zero-customer-payload.mdx` — Verified (file present, 167 lines).
- ISC-4: `test -f d2-signalloom/apps/docs-signalloom/src/content/docs/reference/lawful-basis-assessment.mdx` — Verified (file present, 126 lines).
- ISC-5: `test -f d2-signalloom/apps/docs-signalloom/src/content/docs/reference/inference-provider-ranges.mdx` — Verified (file present, 169 lines).
- ISC-6: `astro.config.mjs` — Verified (5 new sidebar items registered under Operate, Security, Reference).
- ISC-7: `test/acceptance/docs.spec.ts` — Verified (13 pages tested in PAGES array).
- ISC-8: `bun run check` — Verified (0 errors, 0 warnings, 0 hints).
- ISC-9: `bun run audit:links` — Verified (28 pages, 1126 internal links, 0 unresolved links).
- ISC-10: `make demo-agentmaxxing-docs-test` — Verified (13/13 Playwright tests passed in 4.5s in Chromium).
- ISC-11: Anti: Audited markdown files — Verified (zero collection of prompt text, code, secrets, or memory).
- ISC-12: Anti: Audited lawful basis page — Verified (explicitly states DISABLED state and publishes 40 OPEN items).
- ISC-13: Anti: Audited detection runbook — Verified (explicit callout prohibiting developer productivity tracking).
