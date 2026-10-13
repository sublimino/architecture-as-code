# Proposal — Mapping Stub, Tenant App, and Prompt Commit Summarizer HEAD Body Suppression and Method Gates (2026-Q4)

**Status:** Proposed  
**Author:** Antigravity Engineering  
**Date:** 2026-10-13  
**Tag:** `MAPPINGTENANTSUMMARIZERHEAD`  

## Executive Summary

Platform HTTP microservices must enforce RFC 9110 compliance across all endpoints.
Disallowed HTTP methods must receive status 405 Method Not Allowed with explicit Allow headers.
Responses to HEAD requests must never return response body bytes.
This proposal hardens mapping-stub, tenant-app, and prompt-commit-summarizer test suites.

## Background and Context

The mapping-stub service emulates alert mapping and incident retrieval endpoints for Olly replicas.
Prior test suites only rejected POST requests on probe, incident, event, and metric paths.
The test harness lacked coverage for PUT, DELETE, and PATCH HTTP methods.

The tenant-app service generates synthetic application metrics, traces, and dependency calls.
Its test suite previously tested only POST rejection on probes, topology, metrics, and work routes.
The fault injection endpoint tested DELETE and HEAD but omitted PUT and PATCH methods.
Direct handler invocations and body suppression middleware lacked dedicated unit tests.

The prompt-commit-summarizer service generates Git commit messages from diffs using LLM backends.
Its test suite previously omitted PATCH method rejection across probes and root summarization routes.
Path isolation and direct error handler invocations lacked explicit HEAD body suppression checks.

## Problem Statement

1. Mapping-stub test harness omitted PUT, DELETE, and PATCH method checks across seven endpoints.
2. Tenant-app probes, topology, metrics, and work routes lacked PUT, DELETE, and PATCH method tests.
3. Tenant-app fault endpoint omitted PUT and PATCH method rejection tests with Allow headers.
4. Tenant-app direct methodNotAllowed invocations lacked unit test verification.
5. Prompt-commit-summarizer probes omitted PUT, DELETE, and PATCH method rejection tests.
6. Prompt-commit-summarizer root summarization route omitted PATCH method gate verification.
7. Prompt-commit-summarizer path isolation omitted HEAD body suppression checks on 404 responses.
8. Prompt-commit-summarizer direct healthHandler and headResponseWriter calls lacked unit tests.

## Proposed Changes

### 1. Mapping Stub Test Hardening

Harden `TestMappingStubMux_ProbesAndMethods` with a disallowed methods matrix.
Iterate over POST, PUT, DELETE, and PATCH on `/health`, `/healthz`, and `/readyz`.
Iterate over POST, PUT, DELETE, and PATCH on `/incidents` and `/events`.
Iterate over POST, PUT, DELETE, and PATCH on `/metrics`.
Iterate over POST, PUT, DELETE, and PATCH on `/incidents/{correlation_id}`.
Assert status 405 Method Not Allowed with `Allow: GET, HEAD` and non-empty error body.

### 2. Tenant App Test Hardening

Harden `TestTenantAppMux_ProbesAndMethods` with a disallowed methods matrix.
Iterate over POST, PUT, DELETE, and PATCH on `/health`, `/healthz`, and `/readyz`.
Assert status 405 Method Not Allowed with `Allow: GET, HEAD` and non-empty body.
Iterate over POST, PUT, DELETE, and PATCH on `/topology`, `/metrics`, and `/work`.
Assert status 405 Method Not Allowed with `Allow: GET, HEAD` and non-empty body.
Iterate over PUT, DELETE, and PATCH on `/fault` asserting status 405 with `Allow: GET, POST`.
Verify HEAD on `/fault` returns status 405 with `Allow: GET, POST` and zero body bytes.
Add `TestTenantAppMethodNotAllowedDirectAndHEAD` for direct methodNotAllowed invocations.
Assert status 405, correct Allow headers, nosniff headers, and HEAD body suppression.

### 3. Prompt Commit Summarizer Test Hardening

Harden `TestHealth` to test POST, PUT, DELETE, and PATCH across `/health`, `/healthz`, and `/readyz`.
Assert status 405 Method Not Allowed with `Allow: GET, HEAD` and non-empty body.
Harden `TestSummarizeHandlerMethodGatesAndHead` with PATCH method checks.
Assert status 405 Method Not Allowed with `Allow: POST` and non-empty body.
Harden `TestSummarizeHandlerPathIsolation` to verify HEAD requests return 404 with zero body bytes.
Harden `TestMethodNotAllowed` to verify direct HEAD invocations return 405 with zero body bytes.
Add `TestHealthHandlerDirectMethodGatingAndHEAD` for direct healthHandler testing.
Add `TestHeadResponseWriterDirect` to verify direct write suppression in headResponseWriter.

## Verification Plan

Run the Go test suite for mapping-stub.
Run the Go test suite for tenant-app.
Run the Go test suite for prompt-commit-summarizer.
Run the documentation index synchronization suite.
Run the documentation linting suite.
