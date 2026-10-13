# Proposal — Workspace Multi-Tenancy Confinement and Delivery Sanitization (2026-Q4)

**Status:** Proposed
**Author:** Platform Engineering
**Date:** 2026-10-13
**Scope:** hosted-daytona-coder, prompt-commit-summarizer, olly-replica
**Tag:** WORKSPACESANITIZE

## Context

The hosted-daytona-coder service provisions developer workspaces when agents encounter complexity gates.
In parallel, prompt-commit-summarizer generates conventional commit messages from git diff payloads.
The olly-replica delivery packages provide runnable reference implementations of agentic SRE workflows for external clients.

## Problem statement

The hosted-daytona-coder workspace manager lacked tenant isolation and input validation.
Any caller could list or delete workspaces belonging to any tenant across the cluster.
The service also decoded unbounded request bodies, risking memory exhaustion denial of service.
In prompt-commit-summarizer, request and upstream response bodies lacked reading limits.
Furthermore, the client delivery agent in olly-replica hardcoded enterprise SIT endpoints and corporate scope identifiers as fallbacks.
These accidental enterprise configurations leaked internal network topology in client deliverables.

## Proposed changes

First, enforce tenant isolation and input validation in hosted-daytona-coder.
Extract tenant context from headers, query parameters, and request payloads.
Reject cross-tenant operations with HTTP 403 Forbidden.
Restrict workspace listing and deletion to the authenticated tenant.
Validate PVC names and user identifiers against safe naming patterns.
Bound request payload reading to 64 kilobytes.

Second, harden prompt-commit-summarizer with bounded streaming readers.
Limit request body decoding to 1 megabyte.
Limit upstream LLM error and JSON payload reads.
Reject empty or whitespace-only diffs.
Add a comprehensive unit test suite covering health, filtering, truncation, and error handling.

Third, sanitize client delivery configuration in olly-replica.
Replace corporate SIT endpoints and UUID scopes with local in-cluster authentication endpoints.
Add delivery hygiene unit tests to prevent future leakage.

## Security and tenancy impact

Tenants can no longer inspect or delete remote coding workspaces owned by other tenants.
Input validation prevents path traversal and malicious resource injection.
Bounded readers prevent memory exhaustion attacks across agent endpoints.
Sanitized delivery packages protect internal network topology from exposure.

## Verification plan

Run Go unit tests for hosted-daytona-coder verifying tenant isolation, input validation, and payload limits.
Run Go unit tests for prompt-commit-summarizer verifying diff truncation, body limits, and mock LLM calls.
Run pytest for olly-replica authz verifying delivery package hygiene.
Run docs-lint and docs-index-sync BATS suites to ensure clean documentation compliance.
