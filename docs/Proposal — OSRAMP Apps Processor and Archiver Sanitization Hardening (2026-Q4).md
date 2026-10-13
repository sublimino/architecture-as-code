# Proposal: OSRAMP Apps Processor and Archiver Sanitization Hardening

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-osramp-apps/apps/processor/processor.go`, `d2-osramp-apps/apps/processor/processor.sh`, `d2-osramp-apps/apps/processor/processor_test.go`, `d2-osramp-apps/apps/archiver/archiver.go`, `d2-osramp-apps/apps/archiver/archiver_test.go`, `d2-osramp-apps/apps/listener/listener.go`, `d2-osramp-apps/apps/listener/listener_test.go`

## Executive Summary

This proposal hardens task processing and ingestion pipelines across `d2-osramp-apps`.
It eliminates path traversal vulnerabilities in `processor.go` and `processor.sh`.
It prevents wildcard shell injection during task artifact cleanup.
It enforces primary key validation in `archiver.go` before database persistence.
It guarantees non-empty task identifiers in `listener.go`.
It expands test suites across processor, archiver, and listener components.

## Problem Statement

Security reviews identified multiple input validation and containment gaps:
1. In `processor.go`, `prepareTaskCommand` computes `safeID` using `sanitizeTaskID(task.ID)`.
However, it passes the raw `task.ID` in the `TASK_ID` environment variable.
It also serializes the raw `task.ID` into the JSON payload.
2. In `processor.sh`, `parse_task` extracts `TASK_ID` directly via `jq` without sanitization.
Malicious task identifiers containing `../` escape sandbox boundaries in npm install and result paths.
Furthermore, `cleanup_task` passes `TASK_ID` unquoted to `find -name "*${TASK_ID}*"`.
If `TASK_ID` contains `*`, `find` matches and deletes unrelated directories.
3. In `archiver.go`, `processTaskResult`, `processTaskSignature`, and `processSBOMData` execute SQL insertions without verifying required keys.
Empty `task_id` or `sbom_id` values create primary key collisions and corrupt records.
4. In `listener.go`, `processMessage` forwards messages with empty or whitespace identifiers.

## Technical Design

### Processor Task ID Sanitization

In `d2-osramp-apps/apps/processor/processor.go`:
1. In `prepareTaskCommand`, set `task.ID = safeID`.
2. Pass `TASK_ID=safeID` in `cmd.Env`.
3. Ensure `sanitizeTaskID` trims surrounding whitespace.

In `d2-osramp-apps/apps/processor/processor.sh`:
1. In `parse_task`, sanitize `TASK_ID` using character filtering `tr -cd 'a-zA-Z0-9_-'`.
Truncate `TASK_ID` to 64 characters and fall back to `task` if empty.
2. In `validate_arguments`, apply the same character filtering and length limits.
3. In `cleanup_task`, sanitize `TASK_ID` before invoking `find` commands.

### Archiver Key Validation

In `d2-osramp-apps/apps/archiver/archiver.go`:
1. In `processTaskResult`, reject records where `task_id` is empty or whitespace.
2. In `processTaskSignature`, reject records where `task_id` or `algorithm` is empty.
3. In `processSBOMData`, reject records where `sbom_id` or `task_id` is empty.

### Listener Task ID Normalization

In `d2-osramp-apps/apps/listener/listener.go`:
1. In `processMessage`, inspect `task.ID`.
2. If `task.ID` is empty or whitespace, assign a generated fallback identifier `task-<timestamp>`.

## Verification Strategy

1. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v d2-osramp-apps/apps/processor/...`
2. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v d2-osramp-apps/apps/archiver/...`
3. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v d2-osramp-apps/apps/listener/...`
4. `bats d2-osramp-apps/test/processor-stream.bats`
5. `bats test/docs-index-sync.bats`
6. `./scripts/docs-lint.sh "docs/Proposal — OSRAMP Apps Processor and Archiver Sanitization Hardening (2026-Q4).md"`
