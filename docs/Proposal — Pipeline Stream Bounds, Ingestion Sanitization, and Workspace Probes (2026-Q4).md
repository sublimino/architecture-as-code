# Proposal — Pipeline Stream Bounds, Ingestion Sanitization, and Workspace Probes (2026-Q4)

**Status:** Proposed  
**Author:** Subagent (Round 10 Hardening Worker)  
**Date:** 2026-10-13  
**Tag:** `CPAIOSRAMP`  

## 1. Context and Problem Statement

The execution workspaces, message ingestion pipelines, and CI triage handlers require strict operational robustness:

1. **`cpai-engineer` unbounded bodies and path handling**: `POST /tasks` decodes `r.Body` without length limits. An oversized request exhausts memory. The service also lacks `/healthz` and `/readyz` routes. Furthermore, `sanitisePath` does not strip directory traversal segments.
2. **`processor` task file path traversal and panic risk**: `prepareTaskCommand` embeds raw task identifiers into `os.CreateTemp`. Path traversal sequences cause temp file creation errors. In addition, `mustMarshal` panics on unexpected encoding failures.
3. **`listener` unbounded message ingestion**: `processMessage` decodes JetStream payloads without size limits. It also uses exact error string matching in `isConnectionError`. This misses wrapped connection failures.
4. **`archiver` unbounded database payload unmarshaling**: Message handlers unmarshal unconstrained byte slices directly into structs. Large payloads increase memory pressure during batch processing.
5. **`workspace-connector` HTTP timeouts and probe completeness**: The server lacks `ReadHeaderTimeout`. This leaves it exposed to Slowloris attacks. It also lacks a `/health` endpoint.
6. **`triage-ci-worker` probe routing conflict**: The root catch-all handler intercepts `/healthz` and `/readyz` requests. It returns 405 Method Not Allowed on probe checks.

## 2. Proposed Changes

### 2.1 Workspace Sandboxing and Body Bounds in CPAI Engineer
In `d2-signalloom/apps/cpai-engineer`:
- In `main.go`, wrap `r.Body` with `http.MaxBytesReader(w, r.Body, 1<<20)`.
- Register `GET /healthz` and `GET /readyz` routes.
- Trim whitespace on incoming request fields.
- In `executor.go`, strip traversal dots and leading punctuation in `sanitisePath`.
- Clamp `tokenBudget` within valid ranges.
- In `session.go`, clamp task list pagination between 1 and 500 records.

### 2.2 Task ID Sanitization and Marshal Safety in Processor
In `d2-osramp-apps/apps/processor/processor.go`:
- Add `sanitizeTaskID` to strip non-alphanumeric and path separator characters.
- Use sanitized identifiers for temporary file pattern generation.
- Replace panicking `mustMarshal` with safe error-returning `json.Marshal`.

### 2.3 JetStream Message Bounds and Connection Error Handling in Listener
In `d2-osramp-apps/apps/listener/listener.go`:
- Reject task payloads larger than 4 MiB before unmarshaling.
- Expand `isConnectionError` to inspect substring matches for connection dropouts.

### 2.4 Payload Size Guards in Archiver
In `d2-osramp-apps/apps/archiver/archiver.go`:
- Enforce an 8 MiB maximum payload cap before unmarshaling task results, signatures, and SBOM data.

### 2.5 Server Timeouts and Health Routes in Workspace Connector
In `d2-signalloom/apps/workspace-connector/main.go`:
- Register `GET /health` alongside `/healthz` and `/readyz`.
- Set `ReadHeaderTimeout: 10 * time.Second` on `http.Server`.

### 2.6 Probe Routing in Triage CI Worker
In `d2-signalloom/apps/triage-ci-worker/main.go`:
- Register explicit `/healthz` and `/readyz` handlers before the root catch-all route.

## 3. Verification Plan

1. Run unit test suites for `cpai-engineer`, `processor`, `listener`, `archiver`, `workspace-connector`, and `triage-ci-worker`.
2. Add explicit unit tests covering:
   - Sanitization of task identifiers containing path traversal sequences.
   - Rejection of oversized payloads in message listener.
   - Health and ready probe routing across all updated services.
3. Validate documentation sync via `bats test/docs-index-sync.bats`.
