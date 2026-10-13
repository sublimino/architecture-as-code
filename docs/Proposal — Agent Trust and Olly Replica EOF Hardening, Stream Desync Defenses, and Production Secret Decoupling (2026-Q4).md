# Proposal — Agent Trust and Olly Replica EOF Hardening, Stream Desync Defenses, and Production Secret Decoupling (2026-Q4)

## Context
Signal Loom coordinates agent trust boundaries and agentic SRE services across Kubernetes clusters.
The `d2-agent-trust` slice provides SPIFFE identity validation, OpenBao JSON Web Token role verification, and Agent-to-Agent (A2A) protocol communication.
The `olly-replica` slice provides autonomous agent monitoring, authorization policy evaluation (`olly-authz`), and sentinel analysis (`olly-sentinel`).
Both services expose HTTP/1.1 endpoints that parse incoming payloads and manage connection streams.

## Problem Statement
RFC 9112 Section 6 requires strict HTTP stream framing to prevent request smuggling and stream desynchronization attacks.
When a request provides conflicting `Transfer-Encoding: chunked` and `Content-Length` headers, intermediaries and upstream servers can interpret boundaries differently.
In `d2-agent-trust`, `a2a/service.py` did not check for conflicting `Transfer-Encoding` and `Content-Length` headers during body draining and POST processing.
It also lacked checks for missing chunk length line terminators, permitted unbounded trailer counts, and did not close connections upon premature stream EOF.
Furthermore, `a2a/service.py` lacked `OSError` exception handling around socket reads and risked `AttributeError` exceptions when `self.path` was `None`.
In `d2-agent-trust/test/test_contracts.py`, client HTTP connections remained unclosed, leaking file descriptors.
In `olly-replica/apps/authz`, `httputil.py` lacked TE.CL conflict detection, permitted chunked encoding on `read_json` endpoints, and lacked chunk length terminator checks.
In `olly-replica/components/configs`, demo tokens (`llm-guard-token` and `acme-co-authz-dev-secret`) were hardcoded in base manifests.
Staging and production overlays lacked decoupled Kubernetes Secret definitions and Flux envsubst variable mappings.

## Proposed Changes

### 1. Agent Trust TE.CL Desync Defenses and Stream Bounding
We update `d2-agent-trust/a2a/service.py`.
We detect conflicting `Transfer-Encoding` and `Content-Length` headers in `_drain_body` and `do_POST`.
When conflicting headers appear, we set `self.close_connection = True` and return `400 Bad Request` on mutating endpoints.
We verify that chunk length headers end with newline characters before parsing hex values.
We bound chunk trailer reading to a maximum of 32 lines and enforce connection closure on malformed trailers.
We wrap `self.rfile.read()` calls in `OSError` handlers to catch abrupt socket disconnects.
We ensure `self.path` defaults to `"/"` when set to `None` by malformed request handlers.
We update `d2-agent-trust/test/test_contracts.py` to explicitly close HTTP connections and verify TE.CL rejection and EOF handling.

### 2. Olly Replica AuthZ Stream Hardening and Method Gates
We update `olly-replica/apps/authz/authz/httputil.py`.
We detect and reject conflicting `Transfer-Encoding` and `Content-Length` headers in `drain_body` and `read_json`.
We reject chunked transfer encoding in `read_json` to enforce deterministic payload framing.
We bound trailer loops to 32 headers and validate chunk length line terminators.
We catch `OSError` exceptions during body reads and close connections cleanly.
We guard against `NoneType` path attributes in dispatch and query routes.
We update `olly-replica/apps/authz/tests/test_authz.py` with test coverage for TE.CL conflicts, chunked body rejection, and premature EOF.

### 3. Olly Replica Secret Decoupling and Environment Configuration
We update `olly-replica/components/configs/base/llm-guard.yaml` and `base/olly-sentinel.yaml`.
We extract hardcoded `AUTH_TOKEN` and `LLM_GUARD_TOKEN` values into `olly-llm-guard-auth` Secret references.
We create `staging/olly-authz-secret.yaml` and `staging/olly-llm-guard-auth-secret.yaml` with safe Flux envsubst defaults.
We create `production/olly-authz-secret.yaml` and `production/olly-llm-guard-auth-secret.yaml` requiring explicit cluster environment variables.
We update `staging/kustomization.yaml` and `production/kustomization.yaml` to include the decoupled secrets.

## Verification Plan
We run `python3 -m unittest discover -s test` in `d2-agent-trust`.
We run `python3 -m pytest tests -v` in `olly-replica/apps/authz`.
We run `uv run --python 3.12 --with-requirements requirements.txt python -m pytest tests -q` in `olly-replica/apps/sentinel`.
We run `kubectl kustomize` across all `olly-replica/components/configs` overlays.
We run `bats test/docs-index-sync.bats`.
We run `./scripts/docs-lint.sh`.
We run `./scripts/lint-pipefail-grep-q.sh`.
We run `./scripts/check-vacuous-assertions.sh`.
We run `bats test/bats/bats-registry-coverage.bats`.
