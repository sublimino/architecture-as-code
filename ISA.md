---
task: "Deep documentation review, STE-Code alignment, and loose-ends audit"
project: "osramp-demo"
slug: "doc-review-ste-code"
effort: "E4"
effort_source: "classifier"
phase: "complete"
progress: "27/27"
mode: "algorithm"
started: "2026-09-15T18:15:00+01:00"
updated: "2026-09-15T19:43:00+01:00"
---

# ISA: Repository-Wide Documentation Review & STE-Code Standardization

## Problem
Following the rapid delivery and integration of four major engineering missions (Signal Loom Onboarding, Data Protection SLDP, Enforcement & Response SLER, Interactive Demo Console AMXD, and Detective Telemetry SLCD), repository-level documentation has fallen out of synchronization with the actual codebase. Root `AGENTS.md`, `README.md`, `docs/README.md`, and slice documentation files suffer from:
1. Missing directory declarations and inaccurate slice paths (`d2-kagent` mislabeled as a top-level slice, `d2-cpai` and `d2-k8s-afm` missing from layout tables).
2. Outdated route catalogues (e.g. `d2-signalloom/AGENTS.md` listing only 11 of 25+ active routes and omitting 20 of 26 applications).
3. Outdated documentation index in `docs/README.md` claiming 49 records instead of the 333 current engineering records, and omitting the new governance pillars.
4. Absence of visual architecture MermaidJS diagrams in key agent onboarding files.
5. Inconsistent adherence to ASD-STE100 / STE-Code rules (unapproved verbs, overly complex sentence structures, and terminology drift).

## Vision
Every engineer, agent, and external auditor encounters a pristine, consistent, and logically partitioned documentation estate where:
1. Root `AGENTS.md` and `README.md` accurately depict the entire monorepo architecture, shared foundation, and all delivery slices.
2. `docs/README.md` acts as an authoritative, visual, and comprehensive master navigation index with structured cataloguing of all 333+ Signal Loom records.
3. Every slice has a complete, truthful `AGENTS.md` onboarding document with full route maps, component inventories, and test lifecycles.
4. MermaidJS diagrams clearly illustrate system topologies, communication boundaries, and governance reconciliation loops.
5. All documentation strictly adheres to STE-Code (Simplified Technical English for Code, adapted from ASD-STE100): short imperative sentences, approved terminology, zero confusing synonyms, and British English spelling per project standard.
6. 100% of internal Markdown links resolve cleanly with zero dead links.

## Out of Scope
- Modifying underlying Go, Python, or TypeScript application code.
- Deleting historical session records in `MEMORY/WORK/`.
- Modifying proposal files in `docs/Proposal — ...` (which reside in Obsidian vault).

## Principles
1. **Truth to Code**: Documentation must reflect the actual code and manifests in the repository, not aspirational designs.
2. **STE-Code Discipline**: Enforce ASD-STE100 rules adapted for software documentation: simple words, short sentences (≤20-25 words), imperative instructions, and singular terms for single concepts.
3. **Visual Reinforcement**: Use clean MermaidJS flowcharts and block diagrams to illustrate complex multi-slice interactions for human readers.
4. **Click-Through Navigation**: Provide relative GitHub Markdown links for every referenced file, directory, and command so users navigate effortlessly.
5. **Zero Dead Links**: Every link must resolve to a valid file on disk.

## Constraints
1. **Rule 1.11 Consistency**: Use exact defined terms (`slice`, `foundation`, `lane`, `estate`, `hand-off file`, `surface`).
2. **British English (en_GB)**: Maintain UK spelling per project convention (`behaviour`, `synchronise`, `artefact`, `catalogue`).
3. **No Unsigned/Signed Commits Violation**: Unsigned commits only (`git commit --no-gpg-sign`) and scope-less conventional commits.
4. **Proposals Excluded**: Never git commit `docs/Proposal — ...` files.

## Goal
Conduct a comprehensive audit and overhaul of all primary documentation in `osramp-demo`, updating `AGENTS.md`, `README.md`, `docs/README.md`, `d2-signalloom/AGENTS.md`, and creating `d2-cpai/AGENTS.md` with full STE-Code compliance, rich MermaidJS diagrams, verified hyperlinks, and an honest audit of completed cards and follow-up work.

## Criteria
- [x] ISC-1: Audit completed Kanban cards across SLER, AMXD, and SLCD, verifying zero loose ends in current milestones and documenting required follow-up cards.
- [x] ISC-2: Update root `AGENTS.md` with an architectural MermaidJS diagram illustrating the shared foundation stack and all 8 D2 slices.
- [x] ISC-3: Correct the D2 Slices table in `AGENTS.md` (properly locating Kagent under `d2-signalloom/infra/kagent`, adding `d2-cpai`, and adding docs service).
- [x] ISC-4: Update `AGENTS.md` with all recently delivered demo targets (`demo-agentmaxxing-*`, `demo-signalloom-coding-agent-topology`, etc.).
- [x] ISC-5: Update root `README.md` Repository Layout to include all slices (`d2-cpai/`, `d2-k8s-afm/`) and all tools (`tools/audit-gen`, `tools/harness-dash`, `tools/riskctl`).
- [x] ISC-6: Update root `README.md` to document the 2026-Q3 governance capabilities (SLER multi-plane containment, AMXD interactive demo console, SLCD coding agent telemetry, SLDP retention controller).
- [x] ISC-7: Add architectural MermaidJS diagrams to `README.md` illustrating the multi-slice ingestion and governance platform.
- [x] ISC-8: Overhaul `docs/README.md` master index: update Mermaid documentation map to include the governance suite.
- [x] ISC-9: Expand `docs/README.md` Reference and History to categorize all 333+ Signal Loom records across the 6 major delivery missions.
- [x] ISC-10: Overhaul `d2-signalloom/AGENTS.md` with an architectural MermaidJS diagram showing the frontend SPA, API backend, Ingest, Host Sensor, and OpenBao/SPIRE.
- [x] ISC-11: Update `d2-signalloom/AGENTS.md` route table to include all 25+ live dashboard routes from `App.tsx`.
- [x] ISC-12: Document all 26 applications in `d2-signalloom/apps/` within `d2-signalloom/AGENTS.md`.
- [x] ISC-13: Create `d2-cpai/AGENTS.md` providing standard agent onboarding instructions for the CPAI slice.
- [x] ISC-14: Enforce STE-Code rules across all updated documentation (vocabulary swaps, sentence length ≤25 words, imperative instructions, en_GB spelling).
- [x] ISC-15: Verify 100% of internal links resolve without errors using an automated link verification script.
- [x] ISC-16: Anti: Ensure no broken links or orphaned slice directories remain undocumented.
- [x] ISC-17: Create `src/content/docs/security/data-protection-and-erasure.mdx` covering envelope encryption, soft-tombstone lifecycle, and cryptographic shredding with sequence and state diagrams.
- [x] ISC-18: Create `src/content/docs/operate/rbac-formal-analysis.mdx` covering KubeSec-AFM, Z3 BMC, self-escalation, impersonation, collusion, and min-cut remediation with architecture and escalation diagrams.
- [x] ISC-19: Create `src/content/docs/operate/cpai-runtime-proxy.mdx` covering OpenAI-compatible Vertex AI proxy, SPIFFE attestation, and client setup with request flow diagram.
- [x] ISC-20: Create `src/content/docs/operate/kagent-declarative-swarms.mdx` covering CNCF Kagent CRDs, SPIFFE identity, and OpenBao injection with swarm architecture diagram.
- [x] ISC-21: Update `src/content/docs/index.mdx` with comprehensive platform architecture diagram and updated cards.
- [x] ISC-22: Convert `src/content/docs/start/quick-start.md` to `quick-start.mdx` with quick-start lifecycle flowchart diagram and remove `.md`.
- [x] ISC-23: Register all new pages in `astro.config.mjs` sidebar under `Operate agents` and `Security`.
- [x] ISC-24: Update `test/acceptance/docs.spec.ts` with all 17 pages verifying 200 OK, H1 match, sidebar link, and rendered Mermaid SVG bounding box > 0.
- [x] ISC-25: Harden `scripts/docs-render-check.sh` with process group cleanup and `~/.cache/ms-playwright` browser path fallback.
- [x] ISC-26: Verify `docs-signalloom` build (0 check errors, 32 HTML pages, 1414 internal links checked, 0 broken links).
- [x] ISC-27: Verify Playwright acceptance tests pass 100% via `make demo-agentmaxxing-docs-test` (17/17 passed).

## Test Strategy
- ISC-1: Inspect `.kanban-review-ledger.json` and governor reports in `docs/signalloom/`.
- ISC-2, ISC-7, ISC-8, ISC-10: MermaidJS syntax check and visual structure validation.
- ISC-3, ISC-5, ISC-11, ISC-12, ISC-13: Direct file comparison with filesystem and codebase routes.
- ISC-14: Python regex check for STE-Code unapproved words, sentence lengths, and UK spelling.
- ISC-15, ISC-16: Python link-crawler script checking all internal markdown references.
- ISC-17 through ISC-22: `astro check` and `astro build` compilation.
- ISC-23: Astro sidebar link presence audit.
- ISC-24 through ISC-27: `scripts/docs-render-check.sh` and Playwright headless Chromium verification.

## Features
- F1: Kanban Card Delivery Audit & Follow-Up Roadmap Analysis
- F2: Root AGENTS.md Architecture Diagram & Slice Alignment
- F3: Root README.md Layout, Governance Capabilities & Diagrams
- F4: docs/README.md Master Index & 333-Record Categorisation
- F5: d2-signalloom/AGENTS.md Deep Route & Component Catalogue
- F6: d2-cpai/AGENTS.md Slice Onboarding Creation
- F7: STE-Code Standardization & Link Validation Engine
- F8: User Documentation Portal Expansion (`/docs`)

## Decisions
- 2026-09-15T18:18:00+01:00: Selected STE-Code (ASD-STE100 adaptation) as the mandatory style standard across all documentation updates.
- 2026-09-15T18:18:00+01:00: Retained existing Mermaid styling classes while expanding diagrams to give human readers instant visual comprehension of slice boundaries.
- 2026-09-15T18:18:00+01:00: Documented Kagent as a hosted control plane component under `d2-signalloom/infra/kagent` rather than misrepresenting it as an independent root directory.
- 2026-09-15T19:30:00+01:00: Converted `quick-start.md` to MDX to embed an interactive Mermaid lifecycle diagram while maintaining link stability.
- 2026-09-15T19:35:00+01:00: Hardened `docs-render-check.sh` to resolve `PLAYWRIGHT_BROWSERS_PATH` against `${HOME}/.cache/ms-playwright` and terminate setsid process groups cleanly.

## Changelog
- 2026-09-15T18:18:00+01:00: Initialized ISA for repository-wide documentation review and STE-Code standardization.
- 2026-09-15T18:47:00+01:00: Successfully updated all documentation files, created d2-cpai/AGENTS.md, verified 100% internal links, and validated STE-Code rules.
- 2026-09-15T19:42:00+01:00: Expanded user documentation container with 4 new comprehensive guides (SLDP, AFM, CPAI, Kagent), converted quick-start to MDX with lifecycle flowchart, registered in sidebar and Playwright suite, verified with 17/17 tests passing.

## Verification
- ISC-1: Inspected `.kanban-review-ledger.json` (361 reviews across 220 completed cards, 0 in progress/backlog). Follow-up roadmap documented for Milestone 2.
- ISC-2: Added platform architecture Mermaid diagram to root `AGENTS.md`.
- ISC-3: Corrected slices table in `AGENTS.md` (`d2-signalloom/infra/kagent/`, `d2-cpai/AGENTS.md`, `docs-signalloom`).
- ISC-4: Added `demo-agentmaxxing-*` and `demo-signalloom-coding-agent-topology` targets to `AGENTS.md`.
- ISC-5: Added `d2-cpai/`, `d2-k8s-afm/`, `tools/audit-gen/`, `tools/harness-dash/`, `tools/riskctl/` to `README.md`.
- ISC-6: Documented 2026-Q3 governance capabilities (SLER, AMXD, SLCD, SLDP) in `README.md`.
- ISC-7: Added Signal Loom Governance Platform Mermaid diagram to `README.md`.
- ISC-8: Added Agent Governance Suite subgraph to Mermaid flowchart in `docs/README.md`.
- ISC-9: Categorized all 356 Signal Loom records into 6 structured mission tables in `docs/README.md`.
- ISC-10: Added comprehensive Signal Loom platform architecture Mermaid diagram in `d2-signalloom/AGENTS.md`.
- ISC-11: Documented all 34 active routes from `App.tsx` in `d2-signalloom/AGENTS.md`.
- ISC-12: Documented all 27 application directories in `d2-signalloom/apps/` within `d2-signalloom/AGENTS.md`.
- ISC-13: Created `d2-cpai/AGENTS.md` with complete stack table, lifecycle targets, and architecture diagram.
- ISC-14: Audited all 5 files for STE-Code compliance (0 unapproved vocabulary words, sentences <=25 words, UK spelling).
- ISC-15: Automated link verification script checked 85 internal relative links with 0 broken links (100% resolution).
- ISC-16: Tested CI guards: `acceptance-spec-coverage.bats` (7/7 passed), `slcd-ci-parity.bats` (10/10 passed). Zero orphaned slice directories.
- ISC-17: Created `src/content/docs/security/data-protection-and-erasure.mdx` with envelope encryption sequence and tombstone state diagrams.
- ISC-18: Created `src/content/docs/operate/rbac-formal-analysis.mdx` with AFM pipeline flowchart and impersonation graph.
- ISC-19: Created `src/content/docs/operate/cpai-runtime-proxy.mdx` with CPAI proxy sequence diagram and client configs.
- ISC-20: Created `src/content/docs/operate/kagent-declarative-swarms.mdx` with declarative swarm reconciliation diagram.
- ISC-21: Updated `src/content/docs/index.mdx` with full 5-tier architecture flowchart and updated cards.
- ISC-22: Converted `quick-start.md` to `quick-start.mdx` with deployment flowchart diagram.
- ISC-23: Added 4 new items to `astro.config.mjs` sidebar under `Operate agents` and `Security`.
- ISC-24: Updated `PAGES` array in `test/acceptance/docs.spec.ts` to assert all 17 documentation pages.
- ISC-25: Updated `scripts/docs-render-check.sh` with process group termination and `${HOME}/.cache/ms-playwright` fallback.
- ISC-26: `astro check` reported 0 errors; `astro build` produced 32 HTML pages; `audit:links` checked 1,414 internal links with 0 unresolved.
- ISC-27: Ran `make demo-agentmaxxing-docs-test` executing all 17 Playwright acceptance tests in headless Chromium; 17/17 passed (100% green).
