---
task: "SLDP-P1-2: Make encryption and audit writers fail closed"
slug: sldp-p1-2-fail-closed-controls
project: osramp-demo
effort: e3
effort_source: classifier
phase: complete
progress: 22/22
mode: algorithm
started: 2026-09-14T12:35:00+01:00
updated: 2026-09-14T12:42:00+01:00
---

## Problem

Signal-ingest currently contains two dangerous fail-open controls:
1. `NewEncryptorFromKeyString("")` returns a passthrough `NoopEncryptor` with a nil error, causing any deployment with an absent or empty key to silently store sensitive identity identifiers in cleartext without notification.
2. `NopWriter` silently discards every audit event (`return nil`), under an interface comment at `audit.go:51` instructing implementations to "log and continue". Furthermore, mutating operations like `handlePromoteActor` ignore audit write failures, allowing unauthorized or un-audited state changes.
3. The Kubernetes `deployment.yaml` lacked an `IDENTITY_ENCRYPTION_KEY` mapping, meaning deployments were quietly running in unencrypted passthrough mode.

## Vision

Both protective controls fail closed by default. An absent or malformed encryption key halts startup with a fatal error in production mode, permitting `NoopEncryptor` only with an unambiguous explicit opt-in (`INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true` / `IDENTITY_ALLOW_NOOP_ENCRYPTOR=true`). Active passthrough encryption emits persistent periodic warnings throughout process lifetime. Audit persistence failures follow a strict compliance policy where high-stakes operations (such as actor promotion) are refused, and audit writer degradation is visibly exposed. Operators can inspect effective encryption and audit postures directly via the `/health` endpoint.

## Out of Scope

- Modifying SLER, AMXD, or SLCD sources.
- Rewriting or deleting Parquet segments or historical attestation chains.
- Contacting live customer infrastructure or pushing to remote git branches.

## Principles

- **Fail-Safe Defaults**: Any missing, invalid, or degraded protective control must fail closed unless explicitly overridden for local development with unambiguous opt-in naming.
- **Continuous Observability**: Insecure configurations or degraded audit postures must emit persistent warnings and expose status via health endpoints, not hide behind boot-time scroll.
- **Accountability First**: High-stakes identity and authority mutations must refuse execution if their tamper-evident provenance record cannot be durably written.

## Constraints

- All Go code must compile and pass tests under `GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0`.
- Existing test fixtures and dev runs that require `NoopEncryptor` or mock audit writers must remain functional via explicit opt-in.
- Liveness probe (`/healthz`) must not crashloop on external database unavailability, while readiness (`/readyz`) and posture endpoints (`/health`) report degradation accurately.

## Goal

Make encryption key loading and audit writing fail closed by default; enforce explicit development opt-in and persistent logging for passthrough encryption; establish a strict compliance failure policy for audit writes; expose posture via health endpoints; provision deployment keys; and provide 100% test coverage with verifiable proof.

## Criteria

- [x] ISC-1: `identity.NewEncryptorFromKeyString("")` returns an error (`ErrInvalidKey` / `ErrNoopEncryptionNotAllowed`) in default/production mode with no opt-in.
- [x] ISC-2: `identity.NewEncryptorFromKeyString("")` returns `*NoopEncryptor` when `INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true` (or `IDENTITY_ALLOW_NOOP_ENCRYPTOR=true`) is explicitly set.
- [x] ISC-3: `identity.NewEncryptorFromKeyString(validKey)` returns `*AESGCMEncryptor` with 32-byte key.
- [x] ISC-4: `NoopEncryptor` provides a persistent warning mechanism that logs periodic security warnings during process lifetime.
- [x] ISC-5: `audit/audit.go` interface comment at line 51 is updated to state that audit write errors must never be swallowed or discarded.
- [x] ISC-6: `audit.NopWriter` returns `ErrAuditDisabled` on `WriteAuditEvent` unless explicitly constructed with `AllowDiscard: true`.
- [x] ISC-7: `api.handlePromoteActor` fails closed (returns HTTP 503) when `Audit.WriteAuditEvent` fails.
- [x] ISC-8: `api.Handlers` exposes `/health`, `/api/v1/health`, and posture reporting on effective encryption and audit configuration.
- [x] ISC-9: `d2-signalloom/apps/signal-ingest/base/deployment.yaml` and `secrets.yaml` configure `IDENTITY_ENCRYPTION_KEY` so live Kubernetes deployments do not run in unencrypted passthrough mode.
- [x] ISC-10: `identity/repository.go` `NewPostgresRepository` does not silently fall back to `NoopEncryptor` without checking dev mode / requiring non-nil encryptor.
- [x] ISC-11: `go test ./identity/...` passes 100% with new unit tests for production refusal and dev opt-in.
- [x] ISC-12: `go test ./audit/...` passes 100% with fail-closed audit policy assertions.
- [x] ISC-13: `go test ./api/...` passes 100% with health posture and promotion failure tests.
- [x] ISC-14: `make test-signal-ingest` passes 100% with zero regressions.
- [x] ISC-15: Package constructor audit documented across all `New*` constructors in `signal-ingest`.
- [x] ISC-16: `docs/signalloom/sldp-p1-2-proof.md` created with complete execution and test evidence.
- [x] ISC-17: Errata entry for `SLDP-P1-2` added to the Proposal Appendix with `status=pass`.
- [x] ISC-18: Proposal Work Decomposition table updated with the committed SHA in the Result column.
- [x] ISC-19: Anti: Encryption must NOT fail open on empty key in production mode.
- [x] ISC-20: Anti: Audit write failures must NOT be silently discarded on high-stakes operations.
- [x] ISC-21: Anti: No changes to Parquet segment formats or historical attestation records.
- [x] ISC-22: Anti: No remote git pushes or pull requests created.

## Test Strategy

| ISC | Type | Check | Threshold | Tool |
|---|---|---|---|---|
| ISC-1 | Unit | `TestNewEncryptorFromKeyString_ProductionRefusal` | Returns error on empty key | `go test ./identity/...` |
| ISC-2 | Unit | `TestNewEncryptorFromKeyString_DevOptIn` | Returns NoopEncryptor with opt-in env | `go test ./identity/...` |
| ISC-3 | Unit | `TestNewEncryptorFromKeyString_ValidKey` | Returns AESGCMEncryptor | `go test ./identity/...` |
| ISC-4 | Unit | `TestNoopEncryptor_PeriodicWarning` | Emits periodic warning ticker | `go test ./identity/...` |
| ISC-5 | Source | Interface comment in `audit.go` | No swallow/discard guidance | `view_file` |
| ISC-6 | Unit | `TestNopWriter_FailClosed` | Returns ErrAuditDisabled on discard=false | `go test ./audit/...` |
| ISC-7 | Unit | `TestPromoteActor_AuditFailureFailsClosed` | Returns 503 on audit error | `go test ./api/...` |
| ISC-8 | Integration | Health endpoint posture query | Status 200 with posture details | `go test ./api/...` |
| ISC-9 | Config | Deployment and Secret YAML | Contains IDENTITY_ENCRYPTION_KEY | `view_file` |
| ISC-10 | Source | NewPostgresRepository validation | Requires valid encryptor | `view_file` |
| ISC-11..14 | Suite | Full signal-ingest test suite | 100% pass | `make test-signal-ingest` |
| ISC-15 | Doc | Constructor audit section in proof | All New* inspected | `view_file` |
| ISC-16 | Evidence | `sldp-p1-2-proof.md` | Contains full runbook & evidence | `view_file` |
| ISC-17..18 | Proposal | Appendix errata & result update | status=pass recorded | `obsidian-read` |
| ISC-19..22 | Invariant | Negative checks | No regressions or leaks | `git diff` & tests |

## Features

- **Encryption Fail-Closed**: Hardened `NewEncryptorFromKeyString` and `NewPostgresRepository` with unambiguous dev opt-in (`INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR`) and persistent background warning ticker.
- **Audit Fail-Closed**: Hardened `AuditWriter` interface doc, `NopWriter` fail-closed posture, and `handlePromoteActor` refusal on audit failure.
- **Health Posture Reporting**: Endpoints `/health` and `/api/v1/health` reporting effective encryption algorithm, dev opt-in flag, audit backend, and compliance posture.
- **Deployment Manifests**: Key configuration wired in `deployment.yaml` and `secrets.yaml`.

## Decisions

- **2026-09-14 12:37:00+01:00 (AJM/Sensai)**: Selected `INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR` (aliased with `IDENTITY_ALLOW_NOOP_ENCRYPTOR`) to make development passthrough explicitly opt-in and unambiguous.
- **2026-09-14 12:37:00+01:00 (AJM/Sensai)**: Actor promotion (`handlePromoteActor`) strictly fails closed (HTTP 503) if audit logging fails, satisfying GDPR Art 5(2) accountability for high-stakes authority changes.
- **2026-09-14 12:37:00+01:00 (AJM/Sensai)**: Single-agent execution in dedicated worktree; delegation floor relaxed with direct tool execution.

## Changelog

- 2026-09-14: Conjectured that `NewEncryptorFromKeyString` and `NopWriter` could fail open silently in production; refuted by empirical source audit showing empty key returns `NoopEncryptor` and `NopWriter` returns `nil`; learned that explicit dev gating and fail-closed posture are mandatory; criterion now enforced via ISC-1 through ISC-22.

## Verification

- ISC-1: Verified via `TestNewEncryptorFromKeyString_ProductionRefusalOnEmptyKey` in `identity/encryption_test.go`.
- ISC-2: Verified via `TestNewEncryptorFromKeyString_DevelopmentOptInAllowed` in `identity/encryption_test.go`.
- ISC-3: Verified via `TestNewEncryptorFromKeyString_ValidKeyAlwaysSucceeds` in `identity/encryption_test.go`.
- ISC-4: Verified via `TestNoopEncryptor_PersistentWarningCycle` in `identity/encryption_test.go`.
- ISC-5: Verified updated comment in `audit/audit.go:48-54`.
- ISC-6: Verified via `TestNopWriter_FailClosedByDefault` in `audit/audit_test.go`.
- ISC-7: Verified via `TestPromoteActor_AuditFailureFailsClosed` in `api/promote_test.go`.
- ISC-8: Verified via `TestHealth_PostureReporting` in `api/handlers_test.go`.
- ISC-9: Verified `deployment.yaml` and `secrets.yaml` configuration of `IDENTITY_ENCRYPTION_KEY`.
- ISC-10: Verified via `TestNewPostgresRepository_RefusesNilEncryptorInProduction` in `identity/encryption_test.go`.
- ISC-11..14: Verified 100% pass across `make test-signal-ingest`, `make demo-signalloom-api-test TIER=contract`, and `bats test/acceptance-spec-coverage.bats`.
- ISC-15..16: Verified in `docs/signalloom/sldp-p1-2-proof.md`.
- ISC-17..18: Verified errata block written to Proposal Appendix via `obsidian-read`.
- ISC-19..22: Verified zero regressions or negative invariant violations.
