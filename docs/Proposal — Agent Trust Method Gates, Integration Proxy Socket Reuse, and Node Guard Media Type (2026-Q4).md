# Proposal — Agent Trust Method Gates, Integration Proxy Socket Reuse, and Node Guard Media Type (2026-Q4)

## Context and Motivation

Uniform HTTP method semantics and protocol fidelity are essential across platform services.
Monitoring and admission systems dispatch requests to evaluate service health and authorize operations.
Responding servers must return valid headers while suppressing response bodies on HEAD requests.
When endpoints reject unsupported HTTP verbs, RFC 9110 requires an Allow header that enumerates allowed verbs.
Omitting Allow headers or raising generic five-zero-one responses leads to client connection failures.
Socket address reuse prevents address binding collisions under rapid test cycles and restarts.

## Proposed Architectural Hardening

This proposal hardens three architectural subsystems across the platform.

First, the Agent Trust A2A service (`d2-agent-trust/a2a/service.py`) returns four-zero-five Method Not Allowed on unmatched HTTP verbs.
Standard probes and metadata endpoints emit `Allow: GET, HEAD` on invalid methods.
The authorization endpoint emits `Allow: POST` on invalid methods.
The HTTP server class configures socket address reuse.

Second, the Fake Integration Proxy daemon (`d2-signalloom/apps/fake-integration-proxy/server.py`) configures socket address reuse.
This eliminates address binding collisions during test execution.

Third, the Node Capability Guard admission webhook (`d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go`) sets the Content-Type header on probe responses.
Both GET and HEAD requests receive consistent media-type headers.

## Target Components and Concrete Changes

### 1. Agent Trust A2A Method Gates and Socket Configuration

Component path: `d2-agent-trust/a2a/service.py`.
The request handler handles PUT, DELETE, PATCH, and OPTIONS verbs explicitly.
It returns four-zero-five with appropriate Allow headers.
The server class sets `allow_reuse_address` to true.
Unit tests in `d2-agent-trust/test/test_contracts.py` verify four-zero-five status codes, Allow headers, and socket reuse.

### 2. Fake Integration Proxy Socket Configuration

Component path: `d2-signalloom/apps/fake-integration-proxy/server.py`.
The server class sets `allow_reuse_address` to true.
Unit tests in `d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py` verify socket reuse configuration.

### 3. Node Capability Guard Health Probe Content-Type

Component path: `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go`.
The `HandleHealthz` handler sets `Content-Type: text/plain; charset=utf-8`.
Unit tests in `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler_test.go` verify Content-Type presence on GET and HEAD.

## Verification Plan

1. Run Python contract tests in `d2-agent-trust/test/test_contracts.py`.
2. Run Python contract tests in `d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py`.
3. Run Go unit tests in `d2-signalloom/apps/node-capability-guard/pkg/webhook`.
4. Execute `scripts/docs-lint.sh` to confirm zero broken links or style violations.
