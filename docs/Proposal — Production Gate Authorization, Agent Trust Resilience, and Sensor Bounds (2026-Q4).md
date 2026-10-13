# Proposal — Production Gate Authorization, Agent Trust Resilience, and Sensor Bounds (2026-Q4)

## Abstract

This proposal establishes resilient boundary enforcement, server slowloris mitigation, probe routing parity, and rate limiter budget protection across the Signal Loom and Olly Replica platforms. Specifically, it addresses six concrete security and operational vectors: (1) Missing header read timeouts and empty requester audit bypasses in `prod-deploy-gate`, (2) Slowloris denial-of-service vulnerability and probe gaps in `elk-search-mcp`, (3) Unbounded header timeouts in `signal-ingest` core and probe servers, (4) Malformed header crash vulnerabilities and missing probe routes in the Olly `authz` identity plane (`eems-pip`, `plainid-pdp`, `coin-issuer`), (5) Negative byte size budget underflow in `agentmaxxing-host-sensor` artifact hashing rate limiter, and (6) Missing liveness/readiness probes and query-string fragility in `d2-agent-trust` A2A receiver.

## Problem Statement

### 1. Production Deployment Gate Vulnerabilities (`prod-deploy-gate`)
The `prod-deploy-gate` service coordinates human-in-the-loop (HITL) approval tokens for production rollout pipelines. Two key defects existed:
- The standard `http.Server` configured read, write, and idle timeouts, but omitted `ReadHeaderTimeout`. Attackers or compromised workloads could tie up connection pools via slow-header Slowloris attacks.
- Only `/healthz` and `/readyz` endpoints were exposed, returning 404 for standard `/health` probes.
- In `handleGateRequest`, empty or whitespace-only `requester` fields were accepted without validation, degrading the immutable audit trail for cryptographic approvals.

### 2. Olly Replica MCP Server Exposure (`elk-search-mcp`)
The Model Context Protocol (MCP) server for Elasticsearch log search used bare `http.ListenAndServe(listen, mux)`, which does not configure `ReadHeaderTimeout`. Additionally, only `/healthz` was mapped, leaving `/health` and `/readyz` unserved.

### 3. Signal Ingest Header Timeouts (`signal-ingest`)
The primary telemetry ingestion service operates both an authenticated API server and a dedicated probe listener. Both servers lacked explicit `ReadHeaderTimeout` settings. Furthermore, `api.NewProbeHandler` mapped `/healthz` and `/readyz` but omitted `/health`.

### 4. Authz Identity Plane Stream Parsing (`olly-replica/apps/authz`)
In `httputil.read_json`, `int(handler.headers.get("Content-Length", 0) or 0)` raised an unhandled `ValueError` when non-numeric strings were supplied, crashed on malformed inputs, and allowed negative lengths to trigger unbounded reads. Furthermore, unbounded payloads could lead to heap exhaustion. The three microservices (`eems`, `plainid`, `coin`) also lacked `/health` and `/readyz` probe parity.

### 5. Host Sensor Rate Limiter Budget Manipulation (`agentmaxxing-host-sensor`)
In `ratelimit.py`, `RateLimiter.check_candidate` verified that file size was non-negative. However, `RateLimiter.record_consumption` lacked this verification. An adversarial or buggy caller supplying negative byte sizes would append negative values to the window history, artificially reducing the accumulated window byte count and bypassing rate limit caps.

### 6. A2A Receiver Probe and Query Route Fragility (`d2-agent-trust`)
In `a2a/service.py`, `do_GET` compared `self.path` directly against string literals without stripping query strings, failing to match paths with query parameters. Furthermore, `/health`, `/healthz`, and `/readyz` endpoints were completely absent, preventing standard Kubernetes probes from detecting receiver health.

## Proposed Remediation

1. **`prod-deploy-gate`:**
   - Configure `ReadHeaderTimeout: 10 * time.Second` on `http.Server`.
   - Register `/health` handler alongside `/healthz` and `/readyz`.
   - Validate that `req.Requester` is non-empty after trimming whitespace; return `400 Bad Request` if empty.

2. **`elk-search-mcp`:**
   - Replace bare `http.ListenAndServe` with an explicit `&http.Server{ReadHeaderTimeout: 10 * time.Second}`.
   - Register `/health` and `/readyz` probe endpoints returning HTTP 200.

3. **`signal-ingest`:**
   - Configure `ReadHeaderTimeout: 10 * time.Second` on the main HTTP server and `5 * time.Second` on `newProbeServer`.
   - Register `GET /health` in `api.NewProbeHandler` mapping to `handleHealthz`.

4. **`olly-replica/apps/authz`:**
   - Harden `read_json` in `httputil.py` to safely parse `Content-Length`, reject negative lengths, enforce a 4 MiB ceiling, and handle decode failures cleanly.
   - Register `/health` and `/readyz` in `eems.py`, `plainid.py`, and `coin.py`.

5. **`agentmaxxing-host-sensor`:**
   - In `record_consumption`, reject negative file sizes (`size_bytes < 0`) with reason `invalid_negative_file_size`.
   - Ensure strictly monotonic non-negative additions to sliding window history.

6. **`d2-agent-trust`:**
   - Parse `self.path` via `urllib.parse.urlparse(self.path).path` before route matching.
   - Map `/health`, `/healthz`, and `/readyz` to return HTTP 200 `{"status": "ok"}`.

## Verification Plan

- Unit tests for `prod-deploy-gate` verifying requester validation and health endpoints.
- Unit tests for `elk-search-mcp` verifying probe endpoints.
- Unit tests for `signal-ingest` verifying probe handler routing and server initialization.
- Pytest suite in `olly-replica/apps/authz` verifying health endpoints and malformed `Content-Length` resilience.
- Pytest suite in `agentmaxxing-host-sensor` verifying negative byte rejection in `record_consumption`.
- Pytest suite in `d2-agent-trust` verifying health and query-string routing.
- Documentation linting via `bats test/docs-index-sync.bats`.
