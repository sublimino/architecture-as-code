---
task: "Deep documentation review, STE-Code alignment, and loose-ends audit"
project: "osramp-demo"
slug: "doc-review-ste-code"
effort: "E4"
effort_source: "classifier"
phase: "execute"
progress: "16/16"
mode: "algorithm"
started: "2026-09-15T18:15:00+01:00"
updated: "2026-09-15T18:18:00+01:00"
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

## Test Strategy
- ISC-1: Inspect `.kanban-review-ledger.json` and governor reports in `docs/signalloom/`.
- ISC-2, ISC-7, ISC-8, ISC-10: MermaidJS syntax check and visual structure validation.
- ISC-3, ISC-5, ISC-11, ISC-12, ISC-13: Direct file comparison with filesystem and codebase routes.
- ISC-14: Python regex check for STE-Code unapproved words, sentence lengths, and UK spelling.
- ISC-15, ISC-16: Python link-crawler script checking all internal markdown references.

## Features
- F1: Kanban Card Delivery Audit & Follow-Up Roadmap Analysis
- F2: Root AGENTS.md Architecture Diagram & Slice Alignment
- F3: Root README.md Layout, Governance Capabilities & Diagrams
- F4: docs/README.md Master Index & 333-Record Categorisation
- F5: d2-signalloom/AGENTS.md Deep Route & Component Catalogue
- F6: d2-cpai/AGENTS.md Slice Onboarding Creation
- F7: STE-Code Standardization & Link Validation Engine

## Decisions
- 2026-09-15T18:18:00+01:00: Selected STE-Code (ASD-STE100 adaptation) as the mandatory style standard across all documentation updates.
- 2026-09-15T18:18:00+01:00: Retained existing Mermaid styling classes while expanding diagrams to give human readers instant visual comprehension of slice boundaries.
- 2026-09-15T18:18:00+01:00: Documented Kagent as a hosted control plane component under `d2-signalloom/infra/kagent` rather than misrepresenting it as an independent root directory.

## Changelog
- 2026-09-15T18:18:00+01:00: Initialized ISA for repository-wide documentation review and STE-Code standardization.
- 2026-09-15T18:47:00+01:00: Successfully updated all documentation files, created d2-cpai/AGENTS.md, verified 100% internal links, and validated STE-Code rules.

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
