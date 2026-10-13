# Proposal — OSRAMP Ingestion Stream Hardening, Accidental Demo Data Purge, and HTTP Desync Defenses (2026-Q4)

## Context
OSRAMP processes software bill of materials and provenance signatures across the platform.
The ingestion pipeline comprises the NATS listener, the task processor, and the PostgreSQL archiver.
These services exchange work queue tasks, attestation signatures, and SBOM documents over Unix sockets and JetStream.
Additionally, Olly AuthZ and the Netassert controller expose internal HTTP services that accept inbound payloads.

## Problem Statement
The ingestion listener replaces client connections without closing superseded descriptors, causing socket leaks.
It also fails to retain its Unix domain listener, preventing clean termination during shutdown.
The archiver relies on strict string matching for connection errors, dropping wrapped connection resets and broken pipes.
The processor executes incoming tasks without concurrency bounds, risking process exhaustion and out-of-memory panics.
Furthermore, the processor script contains a hardcoded personal Zapier webhook URL in live code.
Production backend secrets also default to test database names and demo credentials.
Finally, HTTP utility functions in Olly AuthZ and Netassert controller lack hex validation and delimiter checks during chunk draining.

## Objectives
1. Eliminate socket descriptor leaks in the listener and ensure graceful Unix listener closure.
2. Align archiver connection error recovery to handle wrapped resets, broken pipes, and JetStream reconnections.
3. Introduce bounded concurrency and resilient socket reconnection in the task processor.
4. Purge accidental demo webhook URLs and configure production database references cleanly.
5. Harden HTTP chunk stream desynchronization defenses across Olly AuthZ and Netassert controller.

## Proposed Changes

### 1. Ingestion Listener and Archiver Hardening
We update `d2-osramp-apps/apps/listener/listener.go` to close superseded client connections whenever a new client connects.
We store the `net.Listener` on the `NATSListener` struct and close it on cleanup to unblock accept loops.
We update `d2-osramp-apps/apps/archiver/archiver.go` to detect connection resets, broken pipes, and wrapped timeout errors case-insensitively.

### 2. Bounded Processor Concurrency and Reconnection
We update `d2-osramp-apps/apps/processor/processor.go` to enforce bounded task concurrency with a semaphore.
We introduce a reconnect loop that recovers when the Unix socket drops or restarts.
We add signal notification to allow running tasks to complete before termination.

### 3. Demo Data and Accidental Webhook Purge
We remove the hardcoded personal Zapier webhook from `d2-osramp-apps/apps/processor/enhance_sbom_with_dependencies.sh`.
We parameterize notification dispatch through `WEBHOOK_URL` with a safe empty fallback.
We update production PostgreSQL and Archivista secrets to use dedicated production database names.

### 4. HTTP Chunk Stream Desynchronization Defenses
We harden `drain_body` in `olly-replica/apps/authz/authz/httputil.py` with hex validation and CRLF delimiter checks.
We set connection closure on premature EOF, negative Content-Length, and oversized payloads.
We apply matching stream desynchronization guards to `d2-signalloom/apps/netassert-controller/server.py`.

## Verification Plan
We execute Go unit tests for listener, processor, and archiver modules.
We run Python test suites for Olly AuthZ and Netassert controller.
We verify zero regressions using BATS suites.
We confirm documentation index consistency with `bats test/docs-index-sync.bats`.
We run `./scripts/docs-lint.sh` to ensure prose compliance.
