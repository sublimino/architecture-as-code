---
task: "AMXD-P3-2: Implement Zero-Payload Inspector widget proving prompt/code confidentiality"
slug: amxd-p3-2-zero-payload-inspector
project: osramp-demo
effort: e3
effort_source: classifier
phase: complete
progress: 16/16
mode: algorithm
started: 2026-09-15T05:03:00+01:00
updated: 2026-09-15T05:07:15+01:00
---

## Problem

The Zero-Payload Inspector proposal previously relied on DOM inspection asserting the absence of prompt/code strings, which passes unconditionally on fixture-fed pages and validates the wrong boundary. The true confidentiality boundary is `d2-signalloom/apps/agentmaxxing-host-sensor/filter.py`'s `AllowlistFilter` (`ALLOWLISTED_PROCESS_ATTRIBUTES`, `ALLOWLISTED_ENVELOPE_FIELDS`, `PROHIBITED_EXPORT_KEYS`, `filter_attributes`), which drops any unapproved key. The UI needs to render the compiled allowlist sets directly derived from `filter.py`, an active drop-count demonstration proving that unapproved fields are stripped, and a verifiable build digest of `filter.py` rather than hardcoded drifting constants.

## Vision

A mathematically provable, traceable Zero-Payload Inspector widget:
1. **Source-Traced Build Manifest**: `scripts/generate-agentmaxxing-allowlist-manifest.mjs` extracts allowlist sets and computes the full SHA-256 digest of `filter.py` into a committed JSON manifest.
2. **CI-Facing Staleness Gate**: The generator script enforces `--check` with distinct exit codes (0 for fresh, 1 for stale, 2 for error), failing CI if `filter.py` drifts without manifest regeneration.
3. **Copyable Build Digest**: Full 64-character SHA-256 digest rendered in monospace with one-click copy and explicit labeling referencing `filter.py`.
4. **Active Drop Count Demonstration**: Interactive demonstration feeding a representative raw event (with allowlisted and non-allowlisted keys like `prompt_text`, `file_contents`) through allowlist filtering, displaying the exact drop count and filtered keys.
5. **Secondary DOM Check**: Repurposes DOM string checks as secondary defense-in-depth, clearly clarifying the primary proof is the kernel/sensor allowlist filter.
6. **Robust Mock/Live Parity**: Sourced from build-time manifest, ensuring zero mock/live divergence.

## Out of Scope

- Modifying `d2-signalloom/apps/agentmaxxing-host-sensor/filter.py` or host sensor internals.
- Direct mutations to backend production databases or modifying SLER enforcement engines.
- Adding arbitrary file descriptor gauges or fabricating unallowlisted metrics.

## Principles

- **Traceable Ground Truth**: UI assertions must trace directly to compiled source code artifacts via cryptographic digests.
- **Active Boundary Proof**: Prove enforcement by demonstrating the active drop of prohibited fields, not by assuming absence in empty fixtures.
- **Zero Drift Tolerance**: Manifest staleness must fail loudly and deterministically at build and test time.

## Constraints

- TypeScript strict typecheck clean (`bun run typecheck`).
- All tests passing in `dashboard-signalloom` with Vitest (`bun run test`).
- Python interpreter availability verified explicitly before running python-based manifest extraction.
- Strict data-testid attributes for Playwright acceptance suite compatibility.

## Goal

Implement `scripts/generate-agentmaxxing-allowlist-manifest.mjs` and `ZeroPayloadInspector.tsx` with full allowlist rendering, active drop-count verification, copyable build digest, staleness detection, and comprehensive Vitest unit tests.

## Criteria

- [x] ISC-1: `scripts/generate-agentmaxxing-allowlist-manifest.mjs` exists and extracts `ALLOWLISTED_PROCESS_ATTRIBUTES`, `ALLOWLISTED_ENVELOPE_FIELDS`, and `PROHIBITED_EXPORT_KEYS` from `filter.py`.
- [x] ISC-2: `generate-agentmaxxing-allowlist-manifest.mjs` computes the full SHA-256 hex digest of `filter.py` content.
- [x] ISC-3: `generate-agentmaxxing-allowlist-manifest.mjs` supports `--check` flag returning exit code 0 when fresh and exit code 1 when stale.
- [x] ISC-4: `generate-agentmaxxing-allowlist-manifest.mjs` checks for `python3` availability and fails explicitly with clear error if missing.
- [x] ISC-5: Target JSON manifest `agentmaxxing-allowlist-manifest.json` is generated and committed.
- [x] ISC-6: `ZeroPayloadInspector.tsx` exists at `d2-signalloom/apps/dashboard-signalloom/src/components/demos/ZeroPayloadInspector.tsx`.
- [x] ISC-7: `ZeroPayloadInspector` renders the compiled allowlist sets with `data-testid="allowlist-list"`.
- [x] ISC-8: `ZeroPayloadInspector` renders the full SHA-256 build digest in copyable monospace format with `data-testid="filter-digest"`.
- [x] ISC-9: `ZeroPayloadInspector` labels the digest clearly as computed from `filter.py` at build time.
- [x] ISC-10: `ZeroPayloadInspector` performs a drop-count demonstration against a sample raw event containing allowlisted and non-allowlisted keys.
- [x] ISC-11: `ZeroPayloadInspector` displays the drop count with `data-testid="drop-count"`.
- [x] ISC-12: `ZeroPayloadInspector` renders a visible staleness warning banner with `data-testid="manifest-staleness-warning"` when passed a manifest with mismatched digest.
- [x] ISC-13: `ZeroPayloadInspector` frames DOM string absence checks as secondary defense-in-depth, not primary proof.
- [x] ISC-14: `ZeroPayloadInspector.test.tsx` passes with 100% assertions covering allowlist rendering, drop count calculation, copy interaction, and staleness detection.
- [x] ISC-15: Mock and live channels render identical manifest-derived allowlist and digest.
- [x] ISC-16: Anti: Zero raw customer source code or prompt tokens are rendered or accepted by the component.

## Test Strategy

- ISC-1..5: Node script execution `node scripts/generate-agentmaxxing-allowlist-manifest.mjs --check` and `--generate`.
- ISC-6..13: Vitest component unit tests rendering `ZeroPayloadInspector` with default and mismatched manifests.
- ISC-14: Vitest test suite `src/components/demos/ZeroPayloadInspector.test.tsx`.
- ISC-15: Test asserting mock vs live parity for allowlist data.
- ISC-16: Test asserting zero prompt text in rendered DOM.

## Features

- Feature 1: Build-time manifest generator script (`scripts/generate-agentmaxxing-allowlist-manifest.mjs`) with `--check` CI contract.
- Feature 2: Committed JSON manifest (`src/data/agentmaxxing-allowlist-manifest.json`).
- Feature 3: React component `ZeroPayloadInspector.tsx` with allowlist sets, drop count demo, build digest, and staleness warning.
- Feature 4: Comprehensive test suite in `ZeroPayloadInspector.test.tsx`.
- Feature 5: Integration into `ConfinementTelemetryPanel.tsx` (Stage 3).

## Decisions

- **Manifest Storage Location**: Place generated manifest at `d2-signalloom/apps/dashboard-signalloom/src/data/agentmaxxing-allowlist-manifest.json` and export types from `ZeroPayloadInspector.tsx`.
- **Python Check in Script**: Execute `python3` safely to introspect AST or import sets directly, guaranteeing robust set extraction regardless of member ordering or whitespace formatting.
- **Exit Code Contract**: Script exits 0 when `--check` matches, 1 when stale/mismatched, 2 for invocation/runtime errors.

## Changelog

- 2026-09-15: Initialized ISA for AMXD-P3-2 Zero-Payload Inspector implementation.
- 2026-09-15: Implemented manifest generator script, JSON manifest, ZeroPayloadInspector component, and 13-test Vitest suite. All 16 criteria verified green.

## Verification

- `node scripts/generate-agentmaxxing-allowlist-manifest.mjs --check` → exit 0 (fresh).
- Deliberate staleness test with mismatched SHA-256 → exit 1 (stale).
- `bun run test --run src/components/demos/ZeroPayloadInspector.test.tsx` → 13/13 passed.
- `bun run test --run src/components/demos/ConfinementTelemetryPanel.test.tsx` → 20/20 passed.
- `bun run typecheck` → exit 0.
- `bunx eslint src/components/demos/ZeroPayloadInspector*` → exit 0 (0 errors, 0 warnings).
- `bun run build` → exit 0 (`✓ built in 2.81s`).
- `bats test/acceptance-spec-coverage.bats` → 7/7 passed.
