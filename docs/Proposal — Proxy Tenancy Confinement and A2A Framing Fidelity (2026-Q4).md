# Proposal — Proxy Tenancy Confinement and A2A Framing Fidelity (2026-Q4)

**Status:** Proposed
**Author:** Platform Engineering
**Date:** 2026-10-13
**Scope:** fe-signalloom, policy-engine, d2-agent-trust
**Tag:** PROXYFRAMING

## Context

fe-signalloom reverse-proxies compliance and policy routes to the Go policy-engine service.
The proxy forwards queries and bodies across the cluster network.
In parallel, d2-agent-trust runs an in-memory A2A receiver service.
The receiver handles SPIFFE identity validation and mints authorization decisions.

## Problem statement

The reverse proxy allowed foreign query parameters to override authenticated tenant context.
When a caller supplied query parameters like tenant or tenant_id, the proxy forwarded them unchanged.
The proxy also accepted foreign tenant values inside JSON bodies on mutating routes.
In the Go policy-engine, handlers silently ignored conflicts between headers and query parameters.
Direct callers could query policies for foreign tenants without validation.
In d2-agent-trust, the A2A HTTP server omitted content-length headers on metadata and decision responses.
Missing framing headers caused persistent HTTP connections to stall or fail on reuse.

## Proposed changes

First, harden proxy_policy_engine in fe-signalloom.
Reject any query parameter or body tenant value that mismatches the authenticated caller with HTTP 403.
Always bind upstream query parameters to the authenticated tenant.
Second, update extractTenant in the Go policy-engine service.
Return an explicit error whenever an X-Tenant-ID header and a tenant query parameter conflict.
Reject conflicting requests with HTTP 403 Forbidden.
Third, add Content-Length and Content-Type headers to all A2A receiver responses.
Ensure reliable framing across persistent HTTP connections.

## Security and tenancy impact

These changes eliminate cross-tenant leakage in proxy routes and upstream handlers.
Tenants cannot view or manipulate policy bundles belonging to other tenants.
A2A receiver framing eliminates socket desynchronization vulnerabilities.

## Verification plan

Verify policy-engine handlers reject cross-tenant query conflicts with Go unit tests.
Verify fe-signalloom proxy routes reject foreign query and body parameters with pytest.
Verify d2-agent-trust A2A responses include framing headers with Python unittest.
Run docs-lint and docs-index-sync to ensure clean documentation compliance.
