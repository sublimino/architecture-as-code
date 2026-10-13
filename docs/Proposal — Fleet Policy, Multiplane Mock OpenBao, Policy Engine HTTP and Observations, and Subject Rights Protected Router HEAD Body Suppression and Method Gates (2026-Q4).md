# Proposal: Fleet Policy, Multiplane Mock OpenBao, Policy Engine HTTP and Observations, and Subject Rights Protected Router HEAD Body Suppression and Method Gates

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fleet-manager`, `d2-signalloom/apps/policy-engine`, `d2-signalloom/apps/signal-ingest`

## Executive Summary

This proposal hardens fleet manager policy routes and multiplane acceptance tests.
It hardens policy engine HTTP and observation endpoints.
It hardens signal ingest subject rights and auth protected router test harnesses.
It enforces RFC 9110 Section 6.4.1 HEAD response body suppression.
It enforces strict HTTP method gates with compliant Allow headers.
It eliminates body leaks and unvalidated verb acceptance.

## Problem Statement

Automated security sweeps identified four protocol vulnerabilities in test harnesses and endpoints.
First, fleet manager policy routes lack comprehensive HEAD and method gating test coverage.
Second, fleet manager multiplane mock OpenBao servers accept arbitrary HTTP verbs unconditionally.
These mock servers fail to reject invalid verbs with status 405.
Third, policy engine HTTP endpoint tests run on an unwrapped ServeMux.
The unwrapped test server lacks RFC 9110 HEAD response body suppression middleware.
The policy observation test harnesses lack HEAD body suppression and method rejection verification.
Fourth, signal ingest subject rights test harness employs a bare no-op metrics fallback.
Unmatched methods and paths receive 200 OK responses instead of explicit rejection.
The subject rights suite lacks validation for HEAD requests on export and erasure routes.

## Technical Design

### Fleet Manager Policy Routes and Mock OpenBao

The fleet manager policy endpoints implement strict method checking.
The policy evaluation endpoint requires POST requests and sets Allow POST headers.
The policy list endpoint allows GET and HEAD requests.
Acceptance test mock OpenBao servers gate incoming verbs.
Non-POST requests to mock OpenBao return status 405 Method Not Allowed.
All HEAD responses return status codes without response bodies.

### Policy Engine HTTP Endpoints and Observations

The policy engine HTTP test server wraps handlers with HEAD body suppression middleware.
Test cases assert that GET policy list returns 200 with zero body bytes on HEAD.
Test cases assert that evaluation and bundle routes reject non-POST requests with status 405.
Observation handlers reject non-POST requests with Allow POST headers.
Evaluation results suppress response bodies when handling HEAD requests.

### Signal Ingest Subject Rights and Auth Protected Router

The subject rights test harness replaces the no-op fallback handler with http.NotFoundHandler.
Unregistered routes and invalid methods fail closed.
The test suite validates Article 15 export endpoints under HEAD requests.
Export endpoints return status 200 with matching Content-Type and zero body bytes.
Article 17 erasure endpoints reject non-POST requests with status 405.
Auth protected router test assertions verify HEAD error response body suppression.

## Verification Strategy

Verification executes unit and integration tests across all affected components.
Tests verify status 200 with zero body bytes for valid HEAD requests.
Tests verify status 405 with proper Allow headers for disallowed verbs.
Documentation sync tests and link audits run without errors.
