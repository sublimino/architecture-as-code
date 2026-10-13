# Proposal — Policy Engine Timeouts, Fleet Server Resiliency, and Sentinel Probe Parity (2026-Q4)

## Abstract

This proposal establishes resilient HTTP server configurations and Slowloris protections.
It standardizes health probe parity across platform and fleet services.
Six areas are fortified:
- `policy-engine`: header timeouts and `/health` route parity.
- `fleet-manager`: header read timeouts.
- `stun-sentinel`: `/health` route parity.
- `factory-appraiser`: server timeouts and probe test isolation.
- `demo-console`: Slowloris defense and health probes.
- `netassert-controller`: `/readyz` readiness probe.

## Problem Statement

### 1. Policy Engine Timeouts and Ingress Probe Parity (`policy-engine`)
The `policy-engine` evaluates CEL policies and FAIR risk models for the fleet.
`ReadHeaderTimeout` was omitted on `&http.Server`.
This omission left connections vulnerable to Slowloris attacks.
Furthermore, `/health` was omitted, causing ingress probes to receive 404 Not Found.

### 2. Fleet Manager HTTP Header Timeout Protection (`fleet-manager`)
The `fleet-manager` controls multi-cluster workload topology and audit events.
Its `http.Server` omitted `ReadHeaderTimeout`.
This allowed unauthenticated clients to hold TCP connections open indefinitely.

### 3. Node Sentinel Probe Route Parity (`stun-sentinel`)
The `stun-sentinel` daemon enforces containment on misbehaving agent pods.
Its routes registered `/healthz` and `/readyz` but omitted `/health`.
This caused external monitoring probes to fail.

### 4. Factory Appraiser Server Hardening and Route Modularization (`factory-appraiser`)
The `factory-appraiser` performs candidate QA validation.
The service invoked bare `http.ListenAndServe`, lacking header read timeout limits.
Additionally, the route mux was constructed inline in `main()`.
This hindered isolated test coverage for probe endpoints.

### 5. Demo Console Slowloris Defense and Probe Parity (`demo-console`)
The `demo-console` provides cluster telemetry and action brokers.
The server executed bare `http.ListenAndServe` with no timeouts.
In addition, only `/api/health` was registered, omitting standard probe paths.

### 6. Netassert Controller Readiness Probe Parity (`netassert-controller`)
The `netassert-controller` orchestrates ephemeral network assertion scans.
Its request dispatcher serviced `/health` and `/healthz` on GET requests.
It omitted standard Kubernetes `/readyz` readiness probes, returning 404 Not Found.

## Proposed Remediation

1. **`d2-signalloom/apps/policy-engine`:**
   - Configure `ReadHeaderTimeout: 10 * time.Second` on `srv`.
   - Register `mux.HandleFunc("/health", handleHealthz)`.
   - Add `TestHealth` in `main_test.go`.

2. **`d2-signalloom/apps/fleet-manager`:**
   - Configure `ReadHeaderTimeout: 10 * time.Second` on `srv`.

3. **`d2-signalloom/apps/stun-sentinel`:**
   - Register `mux.HandleFunc("/health", s.handleHealth)` in `routes()`.
   - Update `TestHealthRoutesStayOpen` in `cmd/stun-sentinel/main_test.go` to assert `/health`.

4. **`d2-signalloom/apps/factory-appraiser`:**
   - Extract `newMux(clock)` to modularize routes.
   - Replace `http.ListenAndServe` with `&http.Server{ReadHeaderTimeout: 10 * time.Second}`.
   - Add `TestHealthProbes` in `main_test.go` verifying `/health`, `/healthz`, and `/readyz`.

5. **`tools/demo-console`:**
   - Register `/health`, `/healthz`, and `/readyz` alongside `/api/health`.
   - Replace `http.ListenAndServe` with `&http.Server{ReadHeaderTimeout: 10 * time.Second}`.
   - Add `TestHealthEndpoints` in `main_test.go`.

6. **`d2-signalloom/apps/netassert-controller`:**
   - Add `"/readyz"` to supported GET probe routes in `server.py`.
   - Add `test_readyz_returns_ok` in `d2-signalloom/apps/netassert-controller/test/test_controller.py`.

## Verification Plan

- Unit tests in `policy-engine` confirming `handleHealthz` serves `/health` with 200 OK.
- Regression tests in `fleet-manager` verifying routes and handlers.
- Unit tests in `stun-sentinel` verifying probes remain open without credentials.
- Unit tests in `factory-appraiser` verifying probe endpoints return 200 OK.
- Unit tests in `demo-console` confirming all health routes return `{ok: true}`.
- Unit tests in `netassert-controller` confirming `/readyz` probe returns 200 OK.
- Documentation linting via `bats test/docs-index-sync.bats`.
