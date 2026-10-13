# Proposal — HTTP-1.1 Keep-Alive Persistence, Framing Desync Defenses, and Stream Draining in Ingest, Fleet, and Proxy Planes (2026-Q4)

## Context
Signal Loom coordinates agent trust boundaries and agentic SRE services across Kubernetes clusters.
The `d2-signalloom` slice provides `fake-integration-proxy`, `netassert-controller`, `signal-ingest`, `fleet-manager`, and `cardvault`.
These microservices handle HTTP traffic across edge ingress, agent telemetry ingestion, fleet containment cascades, and credential vaults.
They communicate over persistent HTTP/1.1 connections through Envoy ingress proxies and in-cluster service meshes.

## Problem Statement
RFC 9112 Section 6 requires strict HTTP stream framing to prevent request smuggling and stream desynchronization attacks.
When a request contains conflicting `Transfer-Encoding` and `Content-Length` headers (TE.CL), proxies and servers can interpret message boundaries differently.
In `fake-integration-proxy`, `server.py` defaulted to `protocol_version = "HTTP/1.0"`, causing connection closure after every request and preventing HTTP/1.1 keep-alive persistence.
Additionally, abrupt client connection resets raised unhandled socket exceptions (`ConnectionResetError`, `BrokenPipeError`, `ConnectionAbortedError`), and `_drain_body` did not reject TE.CL conflicts or bound chunked trailers.
In `netassert-controller`, `server.py` did not check for TE.CL mutual exclusion in `_drain_body` or bound trailer parsing, risking stream desynchronization and socket exhaustion.
In `signal-ingest`, when `ProtectedRouter` denied requests (authentication failures, rate limiting, non-canonical routes) or when `ActingTenantGate` refused gateway requests, the handlers wrote errors without draining `r.Body`. On persistent keep-alive connections, unread request bytes desynchronize subsequent requests.
In `fleet-manager`, `callerKeys.requireAny` refused unauthenticated or unauthorized callers without draining request bodies. Furthermore, `handleResume` decoded unconstrained input into structs without reader bounds.
In `cardvault`, the `http.Server` configured only `ReadHeaderTimeout` and `IdleTimeout`, omitting `ReadTimeout` and `WriteTimeout`. Its authentication gate and GET handlers also omitted body draining, risking slowloris denial-of-service and persistent socket desynchronization.

## Proposed Changes

### 1. Fake Integration Proxy HTTP/1.1 Persistence and TE.CL Defenses
We update `d2-signalloom/apps/fake-integration-proxy/server.py`.
We set `protocol_version = "HTTP/1.1"` on `ProxyHandler` to permit persistent keep-alive connections.
We wrap `handle_one_request` to cleanly handle `ConnectionResetError`, `BrokenPipeError`, and `ConnectionAbortedError` during keep-alive socket teardown.
We update `_drain_body` to detect conflicting `Transfer-Encoding` and `Content-Length` headers, set `close_connection = True`, and return `False`.
We bound chunked trailer line parsing to 32 headers and close connections on malformed stream structures.
We update request handlers to drain request bodies and return `400 Bad Request` with `Connection: close` upon TE.CL conflict.
We add test cases in `d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py` covering HTTP/1.1 persistence, TE.CL rejection, and keep-alive body draining.

### 2. Netassert Controller Stream Hardening
We update `d2-signalloom/apps/netassert-controller/server.py`.
We detect conflicting `Transfer-Encoding` and `Content-Length` headers in `_drain_body`, setting `close_connection = True`.
We bound chunked trailer parsing to 32 lines and enforce connection closure on framing errors.
We add test coverage in `d2-signalloom/apps/netassert-controller/test/test_controller.py` verifying that TE.CL conflicts set `close_connection = True`.

### 3. Fleet Manager Caller Auth Draining and Resume Reader Bounding
We update `d2-signalloom/apps/fleet-manager/callerauth.go` and `main.go`.
In `callerauth.go`, `requireAny` drains unconsumed request bodies using `io.Copy(io.Discard, io.LimitReader(r.Body, 4096))` and closes `r.Body` before writing `401 Unauthorized` and `403 Forbidden` responses.
In `main.go`, `handleResume` bounds payload reading with `io.LimitReader(r.Body, 1<<20)`.

### 4. Signal Ingest Auth Denials and Gateway Refusals Stream Draining
We update `d2-signalloom/apps/signal-ingest/api/auth.go` and `api/static_bearer.go`.
In `auth.go`, `ProtectedRouter.deny` and the non-audited rate-limiting path drain `r.Body` before returning error responses.
In `static_bearer.go`, `ActingTenantGate` drains `r.Body` before returning `400 Bad Request` and `403 Forbidden` gateway errors.

### 5. Cardvault Slowloris Defense and Handler Body Draining
We update `d2-signalloom/apps/cardvault/main.go`.
We add `ReadTimeout: 15 * time.Second` and `WriteTimeout: 15 * time.Second` to `srv := &http.Server` to mitigate slowloris attacks.
We drain `r.Body` in `requireAuth`, `pathTraversalGuardMiddleware`, `handleHealthz`, `handleReadyz`, `handleListCards`, and `handleGetCard`.

## Verification Plan
We run `python3 -m pytest test/` in `d2-signalloom/apps/fake-integration-proxy`.
We run `python3 -m pytest test/` in `d2-signalloom/apps/netassert-controller`.
We run `go test ./...` in `d2-signalloom/apps/fleet-manager`.
We run `go test ./api/...` in `d2-signalloom/apps/signal-ingest`.
We run `go test ./...` in `d2-signalloom/apps/cardvault`.
We run `bats test/docs-index-sync.bats`.
We run `./scripts/docs-lint.sh`.
