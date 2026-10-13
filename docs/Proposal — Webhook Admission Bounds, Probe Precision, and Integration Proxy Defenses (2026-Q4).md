# Proposal — Webhook Admission Bounds, Probe Precision, and Integration Proxy Defenses (2026-Q4)

**Status:** Proposed  
**Author:** Subagent (Round 9 Hardening Worker)  
**Date:** 2026-10-13  
**Tag:** `ADMPROXY`  

## 1. Context and Problem Statement

The platform admission controllers, test probes, and integration gateways require strict operational resilience under load:

1. **`fake-integration-proxy` body drain vulnerabilities**: `_body` parses `Content-Length` via `int(...)` without exception guards. Non-numeric values cause unhandled `ValueError` crashes. Negative values trigger unbounded blocking reads. Oversized headers risk memory exhaustion. The gateway also lacks `/healthz` routing.
2. **`node-capability-guard` unbounded request bodies and Slowloris**: `HandleValidate` calls `io.ReadAll(r.Body)` without bounds. An oversized payload exhausts webhook server memory. The HTTP listener also lacks read header timeouts.
3. **`nono-containment-probe` network errno precision**: `probeMetadataExfil` hardcodes `ENETUNREACH` for any client connection error. Real system environments produce `ECONNREFUSED` or `ETIMEDOUT`.
4. **`cardvault-agent` clock injection bypass**: `autoClaim` calls wall clock `time.Now()` directly. It bypasses injected agent clocks, preventing deterministic testing.
5. **`kusari-agent` health probe completeness**: The HTTP router only serves `/healthz`. Standard cluster ingress gateways probing `/health` or `/readyz` receive 404 or 405 errors.
6. **`fleet-manager` caller key bearer token trimming**: `authenticate` extracts bearer tokens without stripping trailing whitespace. Padded headers trigger false 401 authentication rejections.

## 2. Proposed Changes

### 2.1 Integration Proxy Body Drain Hardening
In `d2-signalloom/apps/fake-integration-proxy/server.py`:
- Wrap `Content-Length` parsing in exception handling.
- Clamp length between 1 byte and 1 MiB.
- Bound `rfile.read` to prevent buffer exhaustion and negative length hangs.
- Add `/healthz` route support in `_dispatch`.

### 2.2 Admission Webhook Stream and Timeout Defense
In `d2-signalloom/apps/node-capability-guard`:
- In `pkg/webhook/handler.go`, bound `r.Body` using `io.LimitReader(r.Body, 4<<20)` (4 MiB limit).
- In `cmd/main.go`, register `/health` and `/readyz` endpoints.
- Configure `http.Server` with `ReadHeaderTimeout: 10 * time.Second`.

### 2.3 Containment Probe Errno Classification
In `d2-signalloom/apps/nono-containment-probe/probes.go`:
- Inspect underlying network errors in `probeMetadataExfil` using `errnoString(err)`.
- Extend `errnoString` to resolve `ECONNREFUSED`, `ENETUNREACH`, `ETIMEDOUT`, and `EEXIST`.

### 2.4 Deterministic Time in Cardvault Auto-Claim
In `d2-signalloom/apps/cardvault-agent/autoclaim.go`:
- Use `a.clock()` instead of bare `time.Now()`.
- Ensure claims carry injected timestamps during test execution.

### 2.5 Probe Endpoints in Kusari Agent
In `d2-signalloom/apps/kusari-agent/main.go`:
- Register `/health` and `/readyz` alongside `/healthz`.

### 2.6 Bearer Token Normalization in Fleet Manager
In `d2-signalloom/apps/fleet-manager/callerauth.go`:
- Apply `strings.TrimSpace` to bearer tokens in `authenticate`.

## 3. Verification Plan

1. Run unit test suites for `fake-integration-proxy`, `node-capability-guard`, `nono-containment-probe`, `cardvault-agent`, `kusari-agent`, and `fleet-manager`.
2. Add explicit unit tests covering:
   - Malformed, negative, and oversized `Content-Length` headers.
   - Padded bearer tokens in `callerauth`.
   - Health and ready probe routing across services.
3. Validate documentation sync via `scripts/docs-lint.sh` and `bats test/docs-index-sync.bats`.
