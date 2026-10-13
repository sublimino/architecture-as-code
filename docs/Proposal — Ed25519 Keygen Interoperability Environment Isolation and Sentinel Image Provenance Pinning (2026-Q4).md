# Proposal — Ed25519 Keygen Interoperability Environment Isolation and Sentinel Image Provenance Pinning (2026-Q4)

- **Author:** Andrew Martin
- **Date:** 2026-10-13
- **Status:** Proposed
- **Tag:** ED25519PROVENANCEPIN

## 1. Problem Statement

Hermetic test suites must run reliably across unprivileged sandboxes and developer environments.
The Ed25519 key generation interoperability test suite failed during offline test runs due to ambient Go toolchain permission errors.
Simultaneously, the sentinel image provenance test suite detected an outdated image tag in deployment manifests after sentinel source changes.
In addition, end-to-end containment tests defaulted evidence output paths to user home directories.
This triggered file system permission failures during sandboxed execution.

## 2. Root Cause Analysis

The Ed25519 test suite invokes Go cryptography packages without configuring isolated Go cache and path environment variables.
In unprivileged test containers, the ambient environment points the Go path to a root-owned directory.
This prevents the Go toolchain from caching checksum database queries.
Furthermore, recent modifications to sentinel source code shifted the computed source fingerprint from `src-30c1a69f5e57` to `src-50c79ef7e84f`.
The daemonset and cold-start catalogs retained the older fingerprint, breaking provenance validation.
Finally, the dual-cluster containment test suite defaulted evidence storage to the invoking user home directory rather than a temporary test directory.

## 3. Proposed Hardening

First, configure isolated Go environment variables in `test/ed25519-keygen-interop.bats`.
Direct the Go path and cache directories to user-writable temporary locations and bypass checksum database queries.
Prepend the Linuxbrew binary path to guarantee consistent compiler selection.
Second, update the pinned sentinel image tag across daemonset manifests and cold-start catalogs to match current source code.
Third, update default evidence directory fallbacks in `test/e2e-dual-cluster-containment.bats` to use BATS temporary storage.

## 4. Verification Plan

Run `bats test/ed25519-keygen-interop.bats` to confirm eight out of eight interoperability tests pass.
Run `bats test/sentinel-image-provenance.bats` to confirm thirteen out of thirteen provenance tests pass.
Run `bats test/docs-index-sync.bats` and `scripts/docs-lint.sh` to confirm documentation index synchronisation and style compliance.
Run `scripts/lint-pipefail-grep-q.sh` and `scripts/check-vacuous-assertions.sh` to confirm zero regression across static analysis checks.
