# Proposal — Ingestion Stream Resiliency and A2A Framing Robustness (2026-Q4)

**Status:** Proposed
**Author:** Antigravity Reliability Engineering
**Date:** 2026-10-13
**Scope:** d2-osramp-apps, d2-agent-trust, olly-replica
**Tag:** STREAMFRAME

## Context

The OSRAMP data plane ingests task executions, builds SBOM packages, and persists forensic records to relational stores.
Inter-agent communication requires strict validation of cryptographic framing, payloads, and execution contexts.
Workloads must remain resilient to transient network retries, connection drops, and large artifact streams.

## Problem statement

Static and behavioral audits uncovered vulnerability points across the ingestion and trust boundaries.
In `d2-osramp-apps/apps/listener/listener.go`, a global unsynchronized socket handle is shared across listener goroutines without mutex synchronization.
When a processor drops connection, setting the global handle to `nil` races against concurrent writes, triggering fatal runtime nil pointer panics.
In `d2-osramp-apps/apps/processor/processor.go`, task consumption relies on `bufio.NewScanner` with default buffer allocation.
When an incoming task exceeds the 64 KiB `MaxScanTokenSize`, the scanner halts with `bufio.ErrTooLong`, freezing subsequent task processing permanently.
In `d2-osramp-apps/apps/archiver/archiver.go`, raw inserts fail on NATS JetStream at-least-once message redeliveries due to unique constraint violations (`23505`), triggering infinite negative-acknowledgment loops.
In `d2-agent-trust/a2a/service.py`, requests with non-dictionary JSON payloads raise unhandled `AttributeError` exceptions that escape the HTTP error handler, leaking 500 error tracebacks.
In `olly-replica/apps/cmd/elk-search-mcp/mcp.go`, internal sub-requests drop the client request context, severing cancellation propagation to Elasticsearch and Prometheus upstreams.

## Proposed changes

First, refactor `d2-osramp-apps/apps/listener/listener.go` to encapsulate socket connection state inside `NATSListener` protected by a `sync.RWMutex`.
Thread-safe connection swapping guarantees that disconnects cannot panic ongoing message writes.
Second, refactor `d2-osramp-apps/apps/processor/processor.go` to use `bufio.Reader` with unbounded line scanning, eliminating the 64 KiB buffer cutoff.
Third, update `d2-osramp-apps/apps/archiver/archiver.go` database insertions to use idempotent `ON CONFLICT (task_id) DO UPDATE` and `ON CONFLICT (sbom_id) DO NOTHING` clauses, enabling seamless redelivery handling without NAK thrashing.
Fourth, enforce a 1 MiB payload limit in `d2-agent-trust/a2a/service.py`.
Validate that incoming JSON is a dictionary.
Capture `AttributeError` to reject invalid payloads cleanly.
Fifth, propagate `r.Context()` in `olly-replica/apps/cmd/elk-search-mcp/mcp.go` using `httptest.NewRequestWithContext`.

## Security and reliability impact

These enhancements prevent unhandled panics and service lockups during high-throughput task processing.
Large SBOM files stream without token length exhaustion.
Duplicate delivery storms in JetStream resolve idempotently without filling system logs or backing up worker queues.
A2A endpoints withstand fuzzing with non-dictionary JSON payloads without stack leakage or memory exhaustion.

## Verification plan

Run Go unit tests verifying thread-safe socket handling and unbounded line reader behavior.
Verify that simulated duplicate task and SBOM inserts succeed without error.
Execute the `d2-agent-trust` contract test suite with fuzzed non-dictionary JSON payloads and over-sized bodies.
Run documentation and style lint checks to ensure index fidelity.
