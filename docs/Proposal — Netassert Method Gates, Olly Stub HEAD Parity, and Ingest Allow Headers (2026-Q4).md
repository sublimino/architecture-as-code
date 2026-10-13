# Proposal — Netassert Method Gates, Olly Stub HEAD Parity, and Ingest Allow Headers (2026-Q4)

## Context and Motivation

Uniform HTTP method semantics and protocol fidelity are essential across platform daemons.
Monitoring systems dispatch GET and HEAD requests to evaluate service health without incurring unnecessary bandwidth overhead.
Responding servers must return valid headers while suppressing response bodies on HEAD requests.
When endpoints reject unsupported HTTP verbs, RFC 9110 requires an Allow header that enumerates allowed verbs.
Omitting Allow headers or leaking response bodies on HEAD requests leads to monitoring failures and connection desynchronization.

## Proposed Architectural Hardening

This proposal hardens three architectural subsystems across the platform.

First, the network assertion controller daemon (`d2-signalloom/apps/netassert-controller/server.py`) returns four-zero-five Method Not Allowed with Allow headers on unmatched methods.
Probe routes emit `Allow: GET, HEAD`, while the scan trigger route emits `Allow: POST`.
The HTTP server class sets `allow_reuse_address` to true to prevent address binding collisions.

Second, the Sentinel synthetic probe listener (`d2-signalloom/apps/signalloom-stun-sentinel/probe.go`) restricts incoming requests to GET and HEAD verbs.
Unsupported verbs return four-zero-five with `Allow: GET, HEAD`.
HEAD requests suppress JSON body transmission while preserving status codes and headers.

Third, the Signal Ingest service (`d2-signalloom/apps/signal-ingest/api/handlers.go`) supplies `Allow: POST` on method rejections.
The privacy erasure endpoint (`d2-signalloom/apps/signal-ingest/api/erasure.go`) sets `Allow: POST` on non-POST verbs.
Delegation creation and revocation handlers (`d2-signalloom/apps/signal-ingest/api/delegations.go`, `d2-signalloom/apps/signal-ingest/api/revocation_handler.go`) enforce `Allow: POST`.
The delegation clamp endpoint enforces `Allow: POST, DELETE`.
Telemetry ingestion and querying handlers (`d2-signalloom/apps/signal-ingest/api/telemetry_handler.go`) return appropriate Allow headers.
Audit webhook receivers (`d2-signalloom/apps/signal-ingest/api/audit/receiver.go`, `d2-signalloom/apps/signal-ingest/api/audit/gke_adapter.go`) return `Allow: POST`.
The deployment manifest image tag (`d2-signalloom/apps/signal-ingest/base/deployment.yaml`) is re-pinned to match the resulting source hash.

## Target Components and Concrete Changes

### 1. Netassert Controller Method Gates and Socket Configuration

Component path: `d2-signalloom/apps/netassert-controller/server.py`.
The `_dispatch` method inspects incoming verbs on known routes.
It returns four-zero-five with appropriate Allow headers when verbs mismatch.
The handler class implements all standard HTTP verbs to avoid five-zero-one responses.
Unit tests in `d2-signalloom/apps/netassert-controller/test/test_controller.py` verify four-zero-five status codes and Allow headers.

### 2. Sentinel Synthetic Probe Gate and Body Suppression

Component path: `d2-signalloom/apps/signalloom-stun-sentinel/probe.go`.
The `syntheticProbeHandler` rejects non-GET and non-HEAD verbs with four-zero-five Method Not Allowed.
It returns `Allow: GET, HEAD` on rejection.
It suppresses the JSON body on HEAD requests.
Unit tests in `d2-signalloom/apps/signalloom-stun-sentinel/probe_test.go` verify method enforcement and body suppression.

### 3. Signal Ingest Ingestion Method Gates and Tag Alignment

Component path: `d2-signalloom/apps/signal-ingest/api/handlers.go`.
Component path: `d2-signalloom/apps/signal-ingest/api/erasure.go`.
Component path: `d2-signalloom/apps/signal-ingest/api/delegations.go`.
Component path: `d2-signalloom/apps/signal-ingest/api/revocation_handler.go`.
Component path: `d2-signalloom/apps/signal-ingest/api/telemetry_handler.go`.
Component path: `d2-signalloom/apps/signal-ingest/api/audit/receiver.go`.
Component path: `d2-signalloom/apps/signal-ingest/api/audit/gke_adapter.go`.
Component path: `d2-signalloom/apps/signal-ingest/base/deployment.yaml`.
Handlers set RFC 9110 Allow headers when rejecting invalid HTTP methods on mutating and query endpoints.
The deployment manifest tag is aligned with the source tree hash.

## Verification Plan

1. Run Python unit tests in `d2-signalloom/apps/netassert-controller`.
2. Run Go unit tests in `d2-signalloom/apps/signalloom-stun-sentinel`.
3. Run Go unit tests in `d2-signalloom/apps/signal-ingest`.
4. Execute `scripts/docs-lint.sh` to confirm zero broken links or style violations.
