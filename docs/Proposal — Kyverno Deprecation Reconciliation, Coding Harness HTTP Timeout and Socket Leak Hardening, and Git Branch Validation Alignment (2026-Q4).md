# Proposal — Kyverno Deprecation Reconciliation, Coding Harness HTTP Timeout and Socket Leak Hardening, and Git Branch Validation Alignment (2026-Q4)

## Context
Signal Loom enforces supply chain trust boundaries, admission control policies, and sandboxed coding harness environments across Kubernetes clusters.
The platform provides native Kubernetes ValidatingAdmissionPolicy (CEL) admission enforcement and two coding agent harnesses: `cpai-engineer` (in-cluster Landlock nono harness) and `hosted-daytona-coder` (hosted remote devcontainer harness).
Branch synchronization continuously propagates verified commits from `integration/slsi-v0.1.0` down to `main`, `master`, and feature branches.

## Problem Statement
In supply chain admission enforcement, Kyverno was previously deprecated in favor of Kubernetes 1.30+ CEL ValidatingAdmissionPolicies (`policy/cel/require-trusted-registry.yaml`, `policy/cel/require-image-digest.yaml`, `policy/cel/admission-demo-bindings.yaml`).
Kyverno cannot be fetched or run in air-gapped appliances.
However, commit `71c6d88d` accidentally reintroduced `policy/kyverno-verify-images.yaml`, added a Kyverno test in `test/slsi-dual-trust.bats`, and caused `scripts/init-tenant.sh` to record the unbundled Kyverno policy path in `dual-trust-verification.json`.
This broke `test/cel-admission-image-trust.bats` and `d2-signalloom/apps/fleet-manager/image_trust_vap_test.go`, which explicitly verify that the unbundled Kyverno admission dependency is gone from the repository.

In the coding agent harnesses (`cpai-engineer` and `hosted-daytona-coder`), HTTP servers previously configured only `ReadHeaderTimeout: 10 * time.Second` without `IdleTimeout`, `ReadTimeout`, or `WriteTimeout`.
This exposed long-lived keep-alive connections to socket starvation and slowloris vulnerabilities.
Additionally, in `hosted-daytona-coder`, `DELETE /workspaces/{id}` and GET handlers did not drain incoming request bodies, risking HTTP/1.1 pipelined socket corruption and connection reset leaks.

In branch validation, `cpai-engineer` permitted branch names with invalid ref characters, `HEAD`, hidden components, and trailing dots.
In contrast, `hosted-daytona-coder` enforced strict branch sanitization.
This discrepancy allowed malformed git ref arguments to reach `git checkout` invocations in `cpai-engineer`.

## Proposed Changes

### 1. Reconcile Kyverno Deprecation with CEL ValidatingAdmissionPolicy
We remove `policy/kyverno-verify-images.yaml`.
We update `scripts/init-tenant.sh` to reference `policy/cel/require-trusted-registry.yaml` in `dual-trust-verification.json`.
We update `test/slsi-dual-trust.bats` to verify the CEL ValidatingAdmissionPolicy rather than the deprecated Kyverno ClusterPolicy.
We isolate Go toolchain directories (`GOPATH`, `GOCACHE`, `GOMODCACHE`) in `test/cel-admission-image-trust.bats` setup to prevent permissions errors in sandboxed environments.

### 2. HTTP Server Keep-Alive Timeouts and Socket Leak Prevention
In both `d2-signalloom/apps/cpai-engineer/main.go` and `d2-signalloom/apps/hosted-daytona-coder/workspace-manager.go`:
We configure explicit `IdleTimeout: 120 * time.Second`, `ReadTimeout: 30 * time.Second`, and `WriteTimeout: 60 * time.Second` on `http.Server`.
In `hosted-daytona-coder`, we ensure incoming request bodies in all handlers are drained and closed via defer handlers to preserve HTTP/1.1 keep-alive connection reuse.

### 3. Git Branch Validation Alignment in cpai-engineer
We update `d2-signalloom/apps/cpai-engineer/main.go`.
We add `branchRegex = regexp.MustCompile("^[a-zA-Z0-9_][a-zA-Z0-9_\\-\\.\\/]*$")`.
We align `validateBranch` to reject `HEAD` and leading dashes.
It also rejects hidden components, `.lock` components, trailing slashes, and invalid characters.
We add unit tests in `d2-signalloom/apps/cpai-engineer/main_test.go` asserting rejection of these malformed branch patterns.

## Verification Plan
1. Run `bats test/slsi-dual-trust.bats` to verify all dual-trust admission tests pass.
2. Run `bats test/cel-admission-image-trust.bats` to verify all 11 CEL image trust admission tests pass.
3. Run `go test -v ./d2-signalloom/apps/fleet-manager -run TestImageTrust` to verify CEL VAP evaluation and absence of Kyverno.
4. Run `go test -v ./d2-signalloom/apps/cpai-engineer/...` to verify branch validation and HTTP server timeouts.
5. Run `go test -v ./d2-signalloom/apps/hosted-daytona-coder/...` to verify workspace manager timeouts and request body draining.
6. Run `make docs-lint` to verify documentation syntax and link integrity.
