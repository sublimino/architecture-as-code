# Proposal — Fleet Manager Route Gates, Policy Engine Method Allow Headers, and Node Guard Admission Defenses (2026-Q4)

## Context and Motivation

Uniform HTTP method semantics and protocol fidelity are essential across microservices, fleet managers, and admission controllers.
Observability probes and API gateways dispatch GET and HEAD requests to monitor platform health.
Responding handlers must return accurate headers while suppressing response bodies on HEAD requests.
When endpoints reject unsupported verbs, RFC 9110 requires an Allow header that lists acceptable verbs.
Omitting Allow headers or rejecting valid HEAD requests creates diagnostic failures and gateway integration drift.

## Proposed Architectural Hardening

This proposal hardens four architectural subsystems across the platform.

First, the Fleet Manager coordinator (`d2-signalloom/apps/fleet-manager/main.go`) adds Allow headers across its mutating and inspection routes.
Read-only routes including topology and policies accept HEAD requests with body suppression.
Mutating routes including stun, recover, resume, deploy, scan, reset, and policy evaluation return four-zero-five with an Allow header specifying POST.

Second, the Fleet Manager remote stun handler (`d2-signalloom/apps/fleet-manager/remote_stun.go`) supports HEAD requests without body transmission.
Query routes emit `Allow: GET, HEAD` on non-GET/HEAD verbs, while acknowledgement routes emit `Allow: POST`.

Third, the Fleet Manager workload and audit endpoints (`d2-signalloom/apps/fleet-manager/workload_handlers.go`, `d2-signalloom/apps/fleet-manager/audit_events.go`) emit RFC 9110 Allow headers on four-zero-five responses.
Workload listings and audit query routes accept HEAD requests cleanly without payload transmission.

Fourth, the Policy Engine observation and compliance endpoints (`d2-signalloom/apps/policy-engine/observations.go`, `d2-signalloom/apps/policy-engine/compliance.go`, `d2-signalloom/apps/policy-engine/pkg/compliance/fleet_scan.go`) supply `Allow: POST` on method rejections.
Error payloads consistently return JSON responses with four-zero-five Method Not Allowed.

Fifth, the Node Capability Guard admission webhook handler (`d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go`) returns `Allow: POST` on unsupported HTTP methods.

## Target Components and Concrete Changes

### 1. Fleet Manager Core Route Gates and HEAD Parity

Component path: `d2-signalloom/apps/fleet-manager/main.go`.
The `handleTopology` and `handlePolicies` handlers permit both GET and HEAD requests, emitting `Allow: GET, HEAD` on rejection.
Both handlers suppress JSON response bodies when processing HEAD requests.
The `handleStun`, `handleRecover`, `handleResume`, `handleDeploy`, `handleScan`, `handleReset`, and `handlePolicyEvaluate` handlers emit `Allow: POST` on four-zero-five.
Unit tests in `d2-signalloom/apps/fleet-manager/main_test.go` verify HEAD responses and Allow headers across all routes.

### 2. Fleet Manager Remote Stun Verification

Component path: `d2-signalloom/apps/fleet-manager/remote_stun.go`.
The `handleRemoteStunState` method supports HEAD requests, suppresses JSON payload output, and returns `Allow: GET, HEAD` on four-zero-five.
The `handleRemoteStunAck` method returns `Allow: POST` on four-zero-five.
Unit tests in `d2-signalloom/apps/fleet-manager/remote_stun_test.go` verify method enforcement and HEAD responses.

### 3. Fleet Manager Workload and Audit Events

Component path: `d2-signalloom/apps/fleet-manager/workload_handlers.go`.
Component path: `d2-signalloom/apps/fleet-manager/audit_events.go`.
The `handleWorkloadReport` handler emits `Allow: POST` on invalid methods.
The `handleWorkloads` handler supports HEAD requests and emits `Allow: GET, HEAD` on invalid methods.
The `handleAuditEvents` handler supports HEAD requests and emits `Allow: GET, HEAD` on invalid methods.
The `handleAuditStream` handler emits `Allow: GET` on invalid methods.
Unit tests in `d2-signalloom/apps/fleet-manager/workload_registry_test.go` and `d2-signalloom/apps/fleet-manager/audit_events_test.go` verify headers and HEAD suppression.

### 4. Policy Engine Observation Evaluation and Compliance Scan Gates

Component path: `d2-signalloom/apps/policy-engine/observations.go`.
Component path: `d2-signalloom/apps/policy-engine/compliance.go`.
Component path: `d2-signalloom/apps/policy-engine/pkg/compliance/fleet_scan.go`.
Handlers return `Allow: POST` on four-zero-five Method Not Allowed responses, maintaining JSON error envelope consistency.
Unit tests in `d2-signalloom/apps/policy-engine/observations_test.go`, `d2-signalloom/apps/policy-engine/compliance_test.go`, and `d2-signalloom/apps/policy-engine/pkg/compliance/fleet_scan_test.go` verify Allow headers.

### 5. Node Capability Guard Admission Webhook Validation

Component path: `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go`.
The `HandleValidate` method emits `Allow: POST` when rejecting non-POST requests.
Unit tests in `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler_test.go` verify Allow headers on rejected verbs.

## Verification Plan

1. Run Go unit tests in `d2-signalloom/apps/fleet-manager`.
2. Run Go unit tests in `d2-signalloom/apps/policy-engine`.
3. Run Go unit tests in `d2-signalloom/apps/node-capability-guard`.
4. Execute `scripts/docs-lint.sh` to confirm zero broken links or style violations.
