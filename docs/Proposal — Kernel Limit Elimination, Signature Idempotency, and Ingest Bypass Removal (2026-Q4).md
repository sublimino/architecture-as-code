# Proposal — Kernel Limit Elimination, Signature Idempotency, and Ingest Bypass Removal (2026-Q4)

**Status:** Proposed
**Author:** Antigravity Reliability Engineering
**Date:** 2026-10-13
**Scope:** d2-osramp-apps, d2-agent-trust, fe-signalloom
**Tag:** KERNELSTREAM

## Context

The OSRAMP data plane processes large Software Bill of Materials (SBOM) packages and dependency graphs.
It archives cryptographic attestations to PostgreSQL and enforces agent trust boundaries.
The platform requires deterministic handling of large payloads.
It must avoid Linux kernel execution boundaries.
It demands RFC-compliant HTTP error status codes.
It requires idempotent relational persistence on message redelivery.
Finally, it must eliminate mock backdoors in production audit ingestion.

## Problem statement

Static analysis, boundary fuzzing, and adversarial review revealed multiple failure points across the estate:

1. **Kernel MAX_ARG_STRLEN E2BIG truncation in task processor**:
   In `d2-osramp-apps/apps/processor/processor.go`, `processTask` passes `TASK_JSON` as an environment variable in `cmd.Env`.
   Linux enforces a hard limit of 128 KiB (`MAX_ARG_STRLEN = 131,072` bytes) per individual environment variable or argument.
   When an SPDX JSON SBOM or dependency payload exceeds 128 KiB, `execve` returns `E2BIG` (`Argument list too long`).
   This crashes `/app/processor` execution.
   Similarly, `d2-osramp-apps/apps/processor/processor.sh` passes `$(cat "$result_file")` and `$npm_task_json` as command arguments to `nats pub`.
   This exposes result publishing to the same `E2BIG` failure on payloads over 128 KiB.

2. **HTTP 403 returned on malformed JSON and headers in A2A service**:
   In `d2-agent-trust/a2a/service.py`, `do_POST` handles request parsing within a broad `try...except` block.
   This block catches `(KeyError, ValueError, AttributeError, PermissionError)` and emits HTTP 403 Forbidden.
   `int(raw_len)` and `json.loads(raw_body)` raise `ValueError` on malformed inputs.
   Consequently, syntax errors in `Content-Length` or malformed JSON payloads return HTTP 403 Forbidden instead of HTTP 400 Bad Request.

3. **Missing idempotency and duplicate rows in task signature persistence**:
   In `d2-osramp-apps/apps/archiver/archiver.go`, `processTaskSignature` executes a raw `INSERT INTO task_signatures`.
   The table uses an auto-incrementing `id BIGSERIAL PRIMARY KEY`.
   It lacks a unique constraint on `(task_id, algorithm)`.
   Therefore, at-least-once message redelivery by NATS JetStream inserts duplicate signature records on every redelivery.

4. **Cryptographic bypass backdoor in production audit ingestion**:
   In `d2-signalloom/apps/fe-signalloom/src/audit_ingest.py`, `verify_session_signature` contains a mock bypass.
   It accepts any signature starting with `test-valid-sig-` or `mock-valid-sig-`.
   Any unauthenticated caller can bypass cryptographic signature verification in production by using these prefixes.

5. **Agent lookup discrepancy between database and memory modes**:
   In `d2-signalloom/apps/fe-signalloom/src/routers/agents.py`, database mode queries `agent_registry` by UUID or by name.
   Memory mode only checked `_AGENTS[tenant_id].get(agent_id)`.
   It failed with HTTP 404 when clients referenced agents by name.

## Proposed changes

1. **Stream task payloads via disk and standard input**:
   Update `d2-osramp-apps/apps/processor/processor.go` to write payloads exceeding 64 KiB to a temporary file.
   Pass this file via `TASK_FILE` with `0644` permissions.
   Unprivileged child processes (`Uid: 65532`) read it safely without argument list overflow.
   Update `d2-osramp-apps/apps/processor/processor.sh` to read `TASK_FILE`, standard input, or `TASK_JSON` via `printf '%s'`.
   Stream results to NATS using `--force-stdin < "$result_file"`.

2. **Differentiate HTTP 400 Bad Request from HTTP 403 Forbidden**:
   In `d2-agent-trust/a2a/service.py`, validate `Content-Length` and parse JSON in dedicated handlers.
   Return HTTP 400 Bad Request on syntax errors, non-dictionary bodies, or invalid lengths.
   Reserve HTTP 403 Forbidden strictly for invalid or unauthorized SPIFFE identities and tokens.

3. **Enforce unique task signatures with idempotent UPSERT**:
   In `d2-osramp-apps/apps/archiver/archiver.go`, create a unique index `idx_task_signatures_task_algo` on `(task_id, algorithm)`.
   Insert with `ON CONFLICT (task_id, algorithm) DO UPDATE`.

4. **Eliminate mock signature backdoors in audit ingestion**:
   In `d2-signalloom/apps/fe-signalloom/src/audit_ingest.py`, remove `test-valid-sig-` and `mock-valid-sig-` bypass branches.
   Require verified SPIFFE HMAC or asymmetric public key signatures on all ingested audit sessions.

5. **Harmonize agent name resolution across storage backends**:
   In `d2-signalloom/apps/fe-signalloom/src/routers/agents.py`, add name-based fallback lookup for agents in memory mode.
   This matches database mode.

## Security and reliability impact

- Eliminates Linux kernel `MAX_ARG_STRLEN` crashes on large SBOM dependencies and forensic payloads.
- Restores RFC-compliant HTTP status semantics for A2A communication.
- Prevents database record duplication during JetStream message redeliveries.
- Closes unauthenticated signature bypass backdoors in live audit logging.
- Guarantees parity between in-memory testing mode and PostgreSQL production storage.

## Verification plan

- Run `go test` in `d2-osramp-apps/apps/processor` verifying task execution with payloads > 131,072 bytes.
- Run `bats d2-osramp-apps/test/processor-stream.bats` verifying `generate_task_result` and `publish_sbom_data` with large payloads.
- Run `go test` in `d2-osramp-apps/apps/archiver` verifying idempotent SQL clauses for `task_signatures`.
- Run `unittest` in `d2-agent-trust` verifying HTTP 400 for malformed JSON and headers.
- Run `pytest` in `d2-signalloom/apps/fe-signalloom` verifying rejection of forged mock signatures.
- Run `scripts/docs-lint.sh` to ensure documentation and link integrity.
