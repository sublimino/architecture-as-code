# Proposal — Archivista Publication, Policy Alert Webhook, GCP Audit PubSub, Prompt Summarizer LLM, and Workspace Ingest Mock Server HEAD Body Suppression and Method Gates (2026-Q4)

## Summary

This proposal hardens test mock servers across five subsystems.
It covers mock Archivista publication servers in signal ingest.
It covers mock decision alert webhook receivers in policy evaluation.
It covers mock Google Cloud Pub/Sub REST servers in GCP audit collection.
It covers mock LLM chat completion servers in prompt commit summarizer.
It covers mock observation ingest servers in workspace connector.

All mock HTTP servers must enforce HTTP method gates.
They must emit standard Allow headers when rejecting unsupported verbs.
They must suppress response bodies on HTTP HEAD requests per RFC 9110 Section 6.4.1.

## Problem Statement

Test suites create mock HTTP endpoints via standard library test helpers.
Many test fixtures omit HTTP method verification.
They accept arbitrary verbs such as GET, PUT, DELETE, or PATCH on mutation routes.
When clients issue probe requests with HTTP HEAD, handlers write message bodies.
RFC 9110 Section 6.4.1 mandates that responses to HEAD requests must not contain a body.
A server that sends a payload for HEAD risks socket desynchronization.
It can cause stream corruption and client decoding errors behind HTTP proxies.

### Affected Components

1. Signal Ingest Store:
   `d2-signalloom/apps/signal-ingest/store/segment_attestor_test.go` creates mock Archivista publication servers.
   These mock servers accept arbitrary verbs on `/upload` and write response bodies on HEAD.

2. Signal Ingest Policy:
   `d2-signalloom/apps/signal-ingest/policy/webhook_test.go` creates mock webhook alert servers.
   These mock servers accept arbitrary HTTP verbs and write response bodies on HEAD.

3. Signal Ingest GCP Audit Collector:
   `d2-signalloom/apps/signal-ingest/collectors/gcpaudit/collector_test.go` creates mock Google Pub/Sub REST servers.
   These mock servers handle `:pull` and `:acknowledge` endpoints without method gating or HEAD body suppression.

4. Prompt Commit Summarizer:
   `d2-signalloom/apps/prompt-commit-summarizer/main_test.go` creates mock LLM chat completion endpoints.
   These mock servers accept arbitrary HTTP verbs without `Allow: POST` headers and leak bodies on HEAD.

5. Workspace Connector:
   `d2-signalloom/apps/workspace-connector/main_test.go` creates mock observation ingest servers.
   These mock servers accept arbitrary HTTP verbs and leak bodies on HEAD.

## Proposed Changes

### 1. HTTP Method Gating

Every mock server handler must validate the incoming HTTP request method.
Mutation endpoints that expect POST must reject non-POST methods.
They must respond with HTTP 405 Method Not Allowed.
They must include an `Allow: POST` header on 405 responses.

### 2. RFC 9110 HEAD Body Suppression

Mock servers must wrap handlers with body suppressing middleware.
Alternatively, handlers must verify whether the method is HEAD before writing payloads.
When a client sends HEAD, the response must carry identical status and headers.
The response payload length must remain strictly zero bytes.

### 3. Verification Test Coverage

Each affected test file must include dedicated test functions.
These tests verify that GET, PUT, and DELETE receive 405 Method Not Allowed.
They verify that Allow headers are present.
They verify that HEAD requests return empty bodies across success and failure paths.

## Implementation Plan

1. Author and index this proposal under Decision Records in `docs/README.md`.
2. Update mock servers in `segment_attestor_test.go` with method gating and HEAD body suppression.
3. Update mock servers in `webhook_test.go` with method gating and HEAD body suppression.
4. Update mock servers in `collector_test.go` with method gating and HEAD body suppression.
5. Update mock servers in `prompt-commit-summarizer/main_test.go` with method gating and HEAD body suppression.
6. Update mock servers in `workspace-connector/main_test.go` with method gating and HEAD body suppression.
7. Add adversarial test functions covering method rejection and HEAD parity.
8. Verify all test suites pass cleanly.
