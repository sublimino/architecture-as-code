# Proposal — Multi-Tenant Boundary Enforcement and Large Artifact Stream Safety (2026-Q4)

> Status: Approved
> Tag: `STREAMBOUND`
> Target Slices: `d2-signalloom`, `d2-osramp-apps`
> Authors: Antigravity Platform Reliability Team
> Date: 2026-10-13

## Context and problem statement

Signal Loom relies on strict tenant isolation across all backend services.
Services must isolate tenants during evaluation, registration, and rollback operations.
An audit identified two critical defects across core platform services.

First, the policy engine allows request body parameters to override authenticated headers.
Callers authenticated as one tenant can evaluate, register, or rollback foreign policies.
This defect breaks the authorization contract defined in the platform test suite.
Gateway proxies forward client payloads without checking body tenant parameters.

Second, the OSRAMP task processor suffers from command-line buffer exhaustion.
Linux kernels enforce a strict limit of 128 KiB per argument.
The processor passed complete software bill of materials data through command arguments.
Large packages produce dependency trees exceeding this limit.
The process terminates with argument list errors, losing critical attestation evidence.

## Proposed architectural changes

### 1. Authoritative tenant scoping in policy engine handlers

The Go policy engine must treat the request header as authoritative.
When a request carries an authenticated tenant header, the body tenant must match.
If the body specifies a different tenant, the engine rejects the request with HTTP 403.
When the body omits the tenant, the engine assigns the header tenant.
Direct API gateway routes in frontend services must enforce the same check.

### 2. Stream-based artifact handling in OSRAMP task processor

The task processor must not place complete artifact payloads on command arguments.
The processor must read bill of materials files directly from the filesystem.
Using JSON file streaming flags eliminates argument size constraints.
Standard input streams carry payloads to messaging queues without shell buffer limits.
Argument parser callers must pass real argument lists rather than default strings.

## Implementation details

### Policy engine and frontend proxy

In `d2-signalloom/apps/policy-engine/handlers.go`:
- Update `HandleEvaluatePolicies` to reject cross-tenant body mismatches with HTTP 403.
- Update `HandleRegisterBundle` to reject cross-tenant bundle mismatches with HTTP 403.
- Update `HandleRollback` to reject cross-tenant rollback mismatches with HTTP 403.

In `d2-signalloom/apps/fe-signalloom/src/routers/policies.py`:
- Add cross-tenant validation to `evaluate_policies`.
- Add cross-tenant validation to `register_bundle`.
- Add cross-tenant validation to `rollback_bundle`.

### OSRAMP task processor

In `d2-osramp-apps/apps/processor/processor.sh`:
- Refactor `publish_sbom_data` to stream the bill of materials file via file flags.
- Pass message payloads to the queue client using stream pipes.
- Replace parameter fallback expansion with standard argument lists in `handle_arguments`.

## Verification record

- Verify policy engine unit and HTTP contract tests using Go test suites.
- Verify frontend policy router isolation tests with pytest.
- Verify processor argument parsing and bill of materials publishing with test scripts.
- Run documentation linting to assert style compliance.
