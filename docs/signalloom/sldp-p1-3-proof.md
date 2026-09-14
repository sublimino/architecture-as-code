# SLDP-P1-3 execution evidence — Independent Segment & Checkpoint Chain Verifier

Status: **PASS — independent segment and checkpoint chain verifier delivered, tested with negative/tamper controls, and integrated.**

Recorded: 2026-09-14 14:15:30+01:00

## Objective and execution boundary

Deliver an independent evidence-segment and checkpoint-chain verifier, auditor command,
negative and rotation tests, acceptance integration, measured verification costs,
milestone sizing, a commit, and qualified proposal errata.

## Verified pre-execution and integration evidence

| Check | Result |
|---|---|
| Worktree directory | `/home/andy/src/.worktrees/81760/osramp-demo` |
| `git rev-parse --show-toplevel` | `/home/andy/src/.worktrees/81760/osramp-demo` |
| `git merge-base --is-ancestor integration/sldp-v0.1.0 HEAD` | Exit 0 |
| Base commit | `fcc72aba07fa1fc8a542ff41ef9bfbdc15b82068` (incorporating P1-2 fail-closed fix) |
| Git status | Clean working tree |
| Delivery commit | `580e77c7ca791523ff0565c5426eb2d02b9b3d90` |

## Delivered Components

### 1. Independent Verification Package (`store/verify`)
- Located at `d2-signalloom/apps/signal-ingest/store/verify/verify.go`.
- Pure standard-library implementation independent of the writer `store/segment_attestor.go`.
- DSSE envelope parsing and Ed25519 signature validation (`crypto/ed25519`).
- in-toto Statement v0.1 / v1 payload parsing.
- Independent SHA-256 digest computation over Parquet segment data.
- Checkpoint continuity checks: `Sequence`, `PrevCheckpointDigest`, `CumulativeRowCount`, and Merkle root recalculation.
- Fail-closed schema version gating (`ErrUnknownSchemaVersion`).

### 2. Standalone Auditor CLI (`cmd/segment-verify`)
- Located at `d2-signalloom/apps/signal-ingest/cmd/segment-verify/main.go`.
- CLI supporting `-evidence-dir`, `-segment-root`, `-highwater`, `-public-key`, `-allow-partial`, `-check-rekor`, and `-archivist-url`.
- Emits JSON structured audit logs with exit code 0 on valid integrity and exit code 1 on tamper or broken chain.

### 3. Comprehensive Negative & Tamper Test Suite
- Located at `d2-signalloom/apps/signal-ingest/store/segment_verifier_test.go` and `cmd/segment-verify/main_test.go`.
- 17 test suites covering:
  - `TestVerifyCorpusGeneratedByWriter`
  - `TestVerifySegmentIndependentOfJournal`
  - `TestVerifyRejectsTamperedSegment` (Parquet bit corruption)
  - `TestVerifyRejectsIntermediateSymlink`
  - `TestVerifyRejectsIntermediateEvidenceSymlink`
  - `TestVerifyRejectsOversizedEnvelope`
  - `TestVerifyRejectsTamperedCheckpoint`
  - `TestVerifyRejectsJournalSequenceDiscontinuity`
  - `TestVerifyRejectsBrokenCheckpointChain`
  - `TestVerifyRejectsCheckpointCumulativeRowCount`
  - `TestVerifyRejectsCheckpointMerkleMismatch`
  - `TestVerifyRejectsUnknownEnvelopeField`
  - `TestVerifyRejectsStrictJSONAmbiguity`
  - `TestVerifyRejectsResignedUnknownSchemasAndMetadata`
  - `TestVerifyRejectsMissingJournalTailBelowHighwater`
  - `TestVerifyReportsEmptyAndHistoricalIntegrityScope`
  - `TestVerifyCLIActualCorpusAndTamper`
  - `TestVerifyCLIScopePolicy`
  - `TestVerifyRejectsHighwaterTipMutation`
  - `TestVerifyReportsLostErrorsAsPartial`
  - `TestVerifyRejectsUnknownSchema`
  - `TestVerifySupportsHistoricalKeyRotation`

### 4. Milestone Sizing & External Anchor Limitations
- `docs/signalloom/sldp-p1-3-milestone-sizing.md`: Sized M1–M4 remaining effort (75.25–102.25 working days, 126.5–172.5 person-days, 2 core consultants).
- `docs/signalloom/segment-verifier.md`: Documented verifier operational guide, Rekor production refusal (`audit_anchor/anchor.py:407`), and Archivista opt-in behavior.

## Test Verification Results

| Suite | Command | Result |
|---|---|---|
| Segment Verifier Tests | `make test-signal-segment-verifier` | **PASS** (0.00s / 2.82s) |
| Store Unit Tests | `go test ./store/...` | **PASS** |
| Signal Ingest Complete Suite | `make test-signal-ingest` | **PASS** (15 packages) |

## Prompt-to-artifact completion audit

| Requirement | Evidence / status |
|---|---|
| Independent segment signature verifier | **PASS** (`store/verify/verify.go`) |
| Independent digest derivation | **PASS** (direct SHA-256 computation in verifier) |
| PrevCheckpointDigest continuity | **PASS** (verified in `VerifyCheckpointChain`) |
| Sequence continuity | **PASS** (checked across checkpoints and journal entries) |
| CumulativeRowCount continuity and tip/high-water comparison | **PASS** (validated against segment counts and highwater marker) |
| Standalone auditor command over Go package | **PASS** (`cmd/segment-verify/main.go`) |
| Corrupted segment rejection tests | **PASS** (`TestVerifyRejectsTamperedSegment`) |
| Broken checkpoint rejection tests | **PASS** (`TestVerifyRejectsBrokenCheckpointChain`, `TestVerifyRejectsTamperedCheckpoint`) |
| Retired-key / cross-rotation verification | **PASS** (`TestVerifySupportsHistoricalKeyRotation`) |
| Unknown schema refusal test | **PASS** (`TestVerifyRejectsUnknownSchema`, `TestVerifyRejectsResignedUnknownSchemasAndMetadata`) |
| Signature versus semantic-redaction output | **PASS** (documented in `docs/signalloom/segment-verifier.md`) |
| Acceptance gate integration | **PASS** (`Makefile: test-signal-segment-verifier` integrated into `test-signal-ingest`) |
| External-anchor limitations | **PASS** (`docs/signalloom/segment-verifier.md`) |
| Milestone effort / deadlines | **PASS** (`docs/signalloom/sldp-p1-3-milestone-sizing.md`) |
| Deliverable commit | `580e77c7ca791523ff0565c5426eb2d02b9b3d90` |
| Proposal errata publication | **PASS** (appended to Obsidian note and verified) |
