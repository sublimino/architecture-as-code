# Proposal — Swarm Coordination, Replica Stubs, Discovery Probes, and Schema Traversal (2026-Q4)

## Abstract

This proposal establishes resilient HTTP server configurations, health probe standardization, input validation, and file path confinement across the Signal Loom swarm coordinator, discovery portal, mock telemetry components, and schema loaders. Six areas are fortified: (1) Missing header read timeouts, probe routes, and empty task description validation in `swarm-governor`, (2) Slowloris vulnerability and missing probes in `mapping-stub`, (3) Slowloris vulnerability and missing probes in `tenant-app`, (4) Missing `/healthz` probe route in `fe-signalloom` FastAPI discovery portal, (5) Missing `/health` route in `cardvault`, and (6) Directory traversal vulnerability in the Olly replica JSON schema loader (`internal/contracts`).

## Problem Statement

### 1. Swarm Governor Timeout and Validation Gaps (`swarm-governor`)
The `swarm-governor` coordinates task decomposition and A2A agent dispatch. Its HTTP server lacked `ReadHeaderTimeout`, exposing it to connection starvation. It omitted the standard `/health` probe route. Furthermore, `handleSubmit` did not validate that `req.Description` was non-empty after trimming, permitting unroutable empty tasks to enter dispatch.

### 2. Mock Mapping Stub Slowloris and Probes (`mapping-stub`)
The mock I/O mapping service used a bare `http.ListenAndServe`, omitting `ReadHeaderTimeout`. Furthermore, only `/healthz` was registered, leaving `/health` and `/readyz` unserved.

### 3. Tenant Application Slowloris and Probes (`tenant-app`)
The synthetic tenant traffic generator used a bare `http.ListenAndServe` without header timeouts and only mapped `/healthz`, causing `/health` and `/readyz` probes to fail.

### 4. Discovery Portal Liveness Probe Parity (`fe-signalloom`)
The primary discovery portal API defined routes for `/api/health`, `/health`, `/livez`, and `/readyz`, but omitted the standard Kubernetes `/healthz` path, causing cluster liveness probes using `/healthz` to receive 404 Not Found.

### 5. Cardvault Probe Route Parity (`cardvault`)
`newMux` in `cardvault` registered `/healthz` and `/readyz` but omitted `/health`, causing non-z-suffixed health checks to fail.

### 6. Schema Loader Directory Traversal (`internal/contracts`)
In `contracts.Load(name)`, the schema name was joined directly with `Dir()` via `filepath.Join(Dir(), name)`. It did not guard against directory traversal sequences (`..`) or absolute paths, allowing callers to escape the contracts directory.

## Proposed Remediation

1. **`swarm-governor`:**
   - Configure `ReadHeaderTimeout: 10 * time.Second` on `srv`.
   - Register `mux.HandleFunc("/health", handleHealthz)`.
   - Validate `strings.TrimSpace(req.Description) != ""` in `handleSubmit`, rejecting empty submissions with `400 Bad Request`.

2. **`mapping-stub`:**
   - Replace `http.ListenAndServe` with an explicit `&http.Server{ReadHeaderTimeout: 10 * time.Second}`.
   - Register `/health` and `/readyz` routes.

3. **`tenant-app`:**
   - Replace `http.ListenAndServe` with an explicit `&http.Server{ReadHeaderTimeout: 10 * time.Second}`.
   - Register `/health` and `/readyz` routes.

4. **`fe-signalloom`:**
   - Add `@app.get("/healthz")` route decorator to the existing `health()` handler in `src/main.py`.

5. **`cardvault`:**
   - Register `mux.HandleFunc("/health", handleHealthz)` in `newMux`.

6. **`internal/contracts`:**
   - In `Load(name)`, reject schema names containing `..` or representing absolute paths with an error before attempting file access.

## Verification Plan

- Unit tests for `swarm-governor` validating description requirements, server timeouts, and probe endpoints.
- Verification of `mapping-stub` and `tenant-app` compilation and route handlers.
- Pytest suite for `fe-signalloom` verifying `/healthz` probe returns 200 OK.
- Go tests in `cardvault` confirming `/health` endpoint.
- Go tests in `internal/contracts` verifying rejection of traversal payloads (`../foo`, `/etc/passwd`) and successful compilation of legitimate schemas.
- Documentation linting via `bats test/docs-index-sync.bats`.
