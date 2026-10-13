# Proposal — CPAI, Agent Trust, and Fake Proxy Lifecycle and Stream Desynchronization Defenses (2026-Q4)

## Context
Signal Loom coordinates cross-boundary services via the Agent Trust slice, the CPAI runtime proxy, and the Fake Integration Proxy.
The Agent Trust service validates SPIFFE SVID identities and OpenBao JSON Web Token roles.
The Fake Integration Proxy simulates external tenant integrations and cluster endpoints.
The CPAI harness dashboard monitors multi-agent sessions and summarizes agent actions across runtime transcripts.

## Problem Statement
RFC 9112 Section 6 requires strict HTTP stream framing to prevent request smuggling and stream desynchronization.
Unbounded request bodies risk memory exhaustion and denial of service.
In `d2-agent-trust`, `a2a/service.py` read only a single bounded buffer during request draining.
It lacked support for chunked transfer encoding draining.
It failed to close persistent connections when receiving oversized payloads.
In `adapters/spire_workload_api.py`, JSON parsing errors suppressed exception causes with `from None`.
In `fake-integration-proxy`, `server.py` lacked chunked body draining.
It sent generic 501 Not Implemented responses with invalid Allow headers on unmapped endpoints.
In `tools/harness-dash`, `cpai.ts` relied on default paths rather than extracting session working directories and tags.
In `summarizer.ts`, Cerebras inference calls lacked explicit timeout bounds.
They also lacked candidate model fallbacks when primary models retired.

## Proposed Changes

### 1. Agent Trust Stream Desynchronization Defenses
We update `d2-agent-trust/a2a/service.py`.
We implement chunked transfer decoding draining with hex length validation up to 1 MiB.
We replace single-chunk draining with looped reading up to the specified content length.
We set connection closure flags on oversized payloads and socket EOF.
We emit `Connection: close` headers whenever connection closure flags trigger.
We ensure status lines precede response headers across all replies.
We bound authorization context and token strings to 16384 bytes.

### 2. SPIRE Workload API Exception Chaining
We update `d2-agent-trust/adapters/spire_workload_api.py`.
We preserve root cause exception chains across JSON parsing errors using `from exc`.

### 3. Fake Integration Proxy Stream and Header Parity
We update `d2-signalloom/apps/fake-integration-proxy/server.py`.
We add chunked transfer encoding draining and oversized payload connection closing.
We emit route-specific Allow headers on 501 Not Implemented responses.
We emit 404 Not Found without Allow headers on unmapped route paths.
We ensure JSON responses emit `Connection: close` when closing connections.
We wire TRACE and CONNECT verbs to safe 501 handlers with request body draining.

### 4. CPAI Adapter and Inference Hardening
We update `tools/harness-dash/src/adapters/cpai.ts`.
We extract working directory paths from parsed transcript fields.
We parse subordinate activities and session tags dynamically.
We update `tools/harness-dash/src/summarizer/summarizer.ts`.
We add an 8-second timeout bound to Cerebras inference requests.
We implement candidate model fallback to `llama3.1-8b` before Gemini Flash fallback.

## Verification Plan
We run `python3 -m unittest discover -s d2-agent-trust/test`.
We run `PYTHONPATH=d2-signalloom/apps/fake-integration-proxy pytest -v d2-signalloom/apps/fake-integration-proxy/test`.
We run `bun test tools/harness-dash/test/harness-dash.test.ts`.
We run `GOCACHE=$(pwd)/.cache/go-build GOMODCACHE=$(pwd)/.cache/go-mod GOPATH=$(pwd)/.cache/go CGO_ENABLED=0 go test -v ./...` in `d2-signalloom/apps/cpai-engineer`.
We run `bats test/docs-index-sync.bats`.
We run `./scripts/docs-lint.sh`.
