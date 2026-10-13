# Proposal — Integration Proxy Method Gates, Prompt Summarizer Allow Headers, and TC Sentinel Defenses (2026-Q4)

## Context and Motivation

Uniform HTTP method semantics and protocol conformance are essential across monitoring, proxy, and agent boundaries.
Probes and API gateways issue both GET and HEAD requests to verify service availability without consuming payload bandwidth.
When endpoints reject unsupported HTTP verbs, RFC 9110 requires an Allow header listing permissible verbs.
Returning four-zero-four Not Found or omitting Allow headers leads to misdirected traffic retries and monitoring alert fatigue.
Additionally, utility libraries such as host sensor rate limiters must enforce scalar typing to prevent NaN corruption and accounting bypasses.

## Proposed Architectural Hardening

This proposal hardens six architectural components across the platform.

First, the integration proxy (`d2-signalloom/apps/fake-integration-proxy/server.py`) adds HEAD dispatching across its primary data inspection routes.
These routes include `/agents`, `/crypto-proofs`, `/trust-topology`, and `/network-tests`.
When client requests supply invalid HTTP verbs for known routes, the dispatcher returns four-zero-five with an Allow header.

Second, the proof helper service (`d2-signalloom/proof-helper/main.go`) sets `Allow: POST` when rejecting non-POST verbs on `/a2a`.
The health probe handler sets `Content-Type: application/json` to maintain media-type fidelity with standard JSON monitoring agents.

Third, the prompt commit summarizer (`d2-signalloom/apps/prompt-commit-summarizer/main.go`) sets `Allow: POST` on its summarization endpoint.
The health handler explicitly sets `Content-Type: text/plain; charset=utf-8` on probe responses.

Fourth, the traffic control sentinel daemon (`d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/main.go`) sets `Allow: POST` on trigger endpoints.
The health handler sets `Content-Type: text/plain; charset=utf-8`.

Fifth, the host sensor rate limiter (`d2-signalloom/apps/agentmaxxing-host-sensor/ratelimit.py`) validates candidate file sizes against non-numeric, boolean, and NaN values.
This check prevents type confusion and rolling window corruption.
Unit tests in `d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py` validate rate limiter boundary enforcement and scalar typing.

Sixth, the Agent-to-Agent trust server (`d2-agent-trust/a2a/service.py`) returns four-zero-five Method Not Allowed when methods do not match route contracts.
The handler returns `Allow: POST` on `/a2a` and `Allow: GET, HEAD` on metadata routes.

## Target Components and Concrete Changes

### 1. Fake Integration Proxy Method Dispatching and Allow Headers

Component path: `d2-signalloom/apps/fake-integration-proxy/server.py`.
The server dispatcher routes HEAD requests to data handlers.
On unsupported methods targeting registered routes, the proxy emits four-zero-five with RFC 9110 compliant Allow headers.
Unit tests in `d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py` verify HEAD handling and Allow headers.

### 2. Proof Helper Method Gates and Content-Type Fidelity

Component path: `d2-signalloom/proof-helper/main.go`.
The server sets `Allow: POST` when rejecting non-POST requests on `/a2a`.
The health probe handler sets `Content-Type: application/json`.
Unit tests in `d2-signalloom/proof-helper/main_test.go` verify the Allow header on `/a2a` and probe headers.

### 3. Prompt Commit Summarizer Allow Headers

Component path: `d2-signalloom/apps/prompt-commit-summarizer/main.go`.
The summarizer route emits `Allow: POST` when rejecting non-POST verbs.
The health handler sets `Content-Type: text/plain; charset=utf-8`.
Unit tests in `d2-signalloom/apps/prompt-commit-summarizer/main_test.go` verify the Allow header.

### 4. Traffic Control Sentinel Allow Headers

Component path: `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/main.go`.
The trigger handler emits `Allow: POST` when rejecting non-POST requests.
The health handler sets `Content-Type: text/plain; charset=utf-8`.
Unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/main_test.go` verify the Allow header on trigger endpoints.

### 5. Host Sensor Rate Limiter Scalar Type Validation

Component path: `d2-signalloom/apps/agentmaxxing-host-sensor/ratelimit.py`.
The `check_candidate` and `record_consumption` methods validate that `size_bytes` is a genuine non-boolean finite number.
The methods return `(False, "invalid_file_size_type")` for invalid types.
Unit tests in `d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py` verify type rejections and window calculations.

### 6. A2A Service Route Method Separation

Component path: `d2-agent-trust/a2a/service.py`.
The HTTP request handler rejects GET and HEAD requests targeting `/a2a` with four-zero-five Method Not Allowed and `Allow: POST`.
The handler rejects POST requests targeting metadata and probe endpoints with four-zero-five and `Allow: GET, HEAD`.
Unit tests in `d2-agent-trust/test/test_contracts.py` verify method gating and header emission.

## Verification Plan

1. Run Python unit tests in `d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py`.
2. Run Go unit tests in `d2-signalloom/proof-helper`.
3. Run Go unit tests in `d2-signalloom/apps/prompt-commit-summarizer`.
4. Run Go unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl`.
5. Run Python unit tests in `d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py`.
6. Run Python unit tests in `d2-agent-trust/test/test_contracts.py`.
7. Execute `scripts/docs-lint.sh` and `bats test/docs-index-sync.bats` to verify documentation integrity.
