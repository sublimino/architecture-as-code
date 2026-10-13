# Proposal — Cardvault, Node Capability Guard, and Factory Appraiser HEAD Body Suppression and Method Gates (2026-Q4)

**Status:** Proposed  
**Author:** Antigravity Engineering  
**Date:** 2026-10-13  
**Tag:** `CARDVAULTNODEGUARDFACAPPRAISERHEAD`  

## Executive Summary

Platform HTTP microservices must enforce RFC 9110 compliance across all endpoints.
Disallowed HTTP methods must receive status 405 Method Not Allowed with explicit Allow headers.
Responses to HEAD requests must never return response body bytes.
This proposal hardens cardvault, node-capability-guard, and factory-appraiser test suites and method matrices.

## Background and Context

The cardvault service stores tokenized payment card records and provides basic auth protected retrieval.
Earlier test coverage checked POST rejection on probe and card routes.
The test harness omitted PUT, DELETE, and PATCH methods in its method rejection matrix.
Direct invocations of the writeJSON helper lacked dedicated unit test verification across status codes.

The node-capability-guard service intercepts Kubernetes pod admission requests.
It verifies kernel containment capabilities and active identity containment records.
Its test suite previously tested POST, PUT, and DELETE rejection on probe routes.
The test suite omitted PATCH method checks across probes, metrics, and admission webhook routes.

The factory-appraiser service evaluates agent candidates against security and temporal freshness policies.
Its test suite previously tested GET and HEAD on health probes.
The suite lacked explicit POST, PUT, DELETE, and PATCH rejection assertions on probes.
The appraise and validate-promotion routes lacked non-POST method matrix tests.

## Problem Statement

1. Cardvault probe and card routes omitted PUT, DELETE, and PATCH checks.
2. Cardvault direct writeJSON invocations lacked unit test coverage for HEAD body suppression.
3. Node-capability-guard probes and metrics omitted PATCH method rejection.
4. Node-capability-guard admission webhook handler omitted PATCH method rejection.
5. Node-capability-guard ServeMux lacked end-to-end method matrix checks on all routes.
6. Factory-appraiser health probes omitted POST, PUT, DELETE, and PATCH rejection checks.
7. Factory-appraiser action endpoints omitted GET, PUT, DELETE, and PATCH rejection assertions.
8. Factory-appraiser action endpoints lacked verification for HEAD 405 empty bodies.

## Proposed Changes

### 1. Cardvault Test Hardening

Harden `TestCardvaultMethodNotAllowed` with PUT, DELETE, and PATCH method checks.
Iterate over `/healthz`, `/readyz`, `/health`, `/api/v1/cards`, and `/api/v1/cards/card-001`.
Assert status 405 Method Not Allowed with `Allow: GET, HEAD` and non-empty error body.
Add `TestCardvaultWriteJSONDirectAndHEAD` for direct writeJSON unit testing.
Verify HEAD requests across status codes suppress response bodies while preserving headers.

### 2. Node Capability Guard Test Hardening

Harden `TestMethodNotAllowed_ProbesAndMetrics` with PATCH method checks.
Verify `/health`, `/healthz`, `/readyz`, and `/metrics` reject disallowed methods with status 405.
Harden `TestMethodNotAllowed_HandleValidate` with PATCH method coverage for server and package handlers.
Harden `TestNewMux_RoutesAndHeadParity` with full mux method matrix verification.
Assert probes reject POST, PUT, DELETE, and PATCH with `Allow: GET, HEAD`.
Assert validate endpoint rejects GET, PUT, DELETE, and PATCH with `Allow: POST`.

### 3. Factory Appraiser Test Hardening

Harden `TestHealthProbes` with POST, PUT, DELETE, and PATCH rejection checks.
Assert status 405 Method Not Allowed with `Allow: GET, HEAD`.
Add `TestMethodRejection_FactoryRoutes` for appraise and validate-promotion endpoints.
Iterate over GET, PUT, DELETE, and PATCH methods asserting status 405 with `Allow: POST`.
Verify HEAD requests receive status 405 with `Allow: POST` and zero body bytes.

## Verification Plan

1. Run `go test -v ./...` in `d2-signalloom/apps/cardvault`.
2. Run `go test -v ./...` in `d2-signalloom/apps/node-capability-guard`.
3. Run `go test -v ./...` in `d2-signalloom/apps/factory-appraiser`.
4. Run `bats test/docs-index-sync.bats` to verify documentation indexing.
