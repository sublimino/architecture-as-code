---
project: osramp-demo
task: "SLDC-P3-GOV: Phase 3 Governor: tenant routing & isolation verification"
slug: sldc-p3-gov-tenant-routing-and-isolation
effort: E3
phase: observe
progress: 0/12
mode: algorithm
started: "2026-09-30T08:39:20+01:00"
updated: "2026-09-30T08:39:20+01:00"
---

## Problem
Phase 3 implementations (SLDC-P3-1 and SLDC-P3-2) have implemented the canonical salted SHA-256 tenant hash generator (`kusari` -> `4b53ab6b`) and Gateway API HTTPRoute + Dex redirect URI alignment. Before proceeding to Phase 4 (cAdvisor telemetry pipeline), governance gate verification must certify clean non-fast-forward integration, verify cryptographic hash test vectors across all implementations, prove fail-closed cross-tenant boundary isolation (HTTP 403 Forbidden), and confirm repository-wide eradication of legacy typo `kurasi`.

## Vision
Complete tenant isolation certified with cryptographic rigor. Ingress routing to `sl-eap-4b53ab6b.ts.net` proxies seamlessly to `fe-signalloom` with security headers, cross-tenant spoofing and legacy header injection fail closed with HTTP 403, and verifiable evidence artifacts provide definitive assurance for Phase 4 advancement.

## Out of Scope
- Implementing application features or cAdvisor metrics pipeline (Phase 4).
- Pushing to remote git origin.
- Modifying cluster manifests outside Phase 3 deliverables.

## Principles
- Fail-Closed Security: Unknown or mismatched tenant identifiers must be rejected with 403 Forbidden.
- Empirical Verification: Every claim must be substantiated by automated test probes and trace logs.
- Falsification Assurance: Mutation tests must prove gates reject deliberately reintroduced flaws.

## Constraints
- Base Ref: `refs/heads/integration/sldc-v0.1.0`.
- Unsigned commits (`git commit --no-gpg-sign`).
- Non-fast-forward merge (`--no-ff`).
- Zero tolerance for legacy typo `kurasi` / `6f82ad81` across codebase.

## Goal
Execute the Phase 3 Governance gate: integrate Phase 3 feature branches into `integration/sldc-v0.1.0`, verify cryptographic hash derivation vectors across Go, Python, and TypeScript, execute positive routing and negative adversarial cross-tenant probes against Envoy Gateway, perform deliberate mutation testing, and generate certification evidence artifacts with sign-off in proposal errata.

## Criteria
- [ ] ISC-1: Merge feat/sldc-p3-1 and feat/sldc-p3-2 cleanly into integration/sldc-v0.1.0 with 0 merge conflicts.
- [ ] ISC-2: Verify cryptographic vector test matrix confirms derive_tenant_hash('kusari') == '4b53ab6b' across Python, Go, and TypeScript.
- [ ] ISC-3: Verify unsalted hash 'd9d69501' and legacy raw sha256 are flagged as non-canonical/invalid.
- [ ] ISC-4: Verify input 'kurasi' is strictly rejected with non-zero exit code across all derivation implementations.
- [ ] ISC-5: Verify test/tenant-hash-vectors.bats executes with 100% pass rate.
- [ ] ISC-6: Verify deploy/eap-tenant-httproute.yaml and d2-signalloom/infra/dex/dex-config-eap.yaml are valid and deployed to kind-signalloom-hub.
- [ ] ISC-7: Verify HTTP GET to Envoy Gateway with Host 'sl-eap-4b53ab6b.ts.net' returns HTTP 200 with security headers.
- [ ] ISC-8: Verify HTTP GET with invalid header 'X-Tenant-ID: kurasi' returns HTTP 403 Forbidden.
- [ ] ISC-9: Verify HTTP GET with cross-tenant host 'sl-eap-6f82ad81.ts.net' returns HTTP 404/403 rejection.
- [ ] ISC-10: Verify repository-wide scan confirms 0 occurrences of 'kurasi' or '6f82ad81' in non-doc codebase files.
- [ ] ISC-11: Anti: No cross-tenant request or spoofed header shall return HTTP 200 or leak tenant data.
- [ ] ISC-12: Anti: Deliberate mutation of tenant filter policy or test vectors must fail tests (falsification proof).

## Test Strategy
- ISC-1 | integration | git merge --no-ff --no-commit | exit 0, 0 conflicts | git
- ISC-2 | unit | python3 test/unit/test_tenant_hash_matrix.py | exit 0, 100% pass | python3
- ISC-3 | unit | python3 test/unit/test_tenant_hash.py | exit 0, 100% pass | python3
- ISC-4 | unit | bun test test/unit/tenant-hash.test.ts | exit 0, 100% pass | bun
- ISC-5 | unit | bats test/tenant-hash-vectors.bats | exit 0, 100% pass | bats
- ISC-6 | integration | kubectl get httproute, envoy config check | exit 0, accepted | kubectl
- ISC-7 | integration | curl -i -H 'Host: sl-eap-4b53ab6b.ts.net' http://localhost:30080 | HTTP 200 | curl
- ISC-8 | integration | curl -i -H 'Host: sl-eap-4b53ab6b.ts.net' -H 'X-Tenant-ID: kurasi' http://localhost:30080 | HTTP 403 | curl
- ISC-9 | integration | curl -i -H 'Host: sl-eap-6f82ad81.ts.net' http://localhost:30080 | HTTP 404/403 | curl
- ISC-10 | integration | ! git grep -E "(kurasi|6f82ad81)" -- ":!docs/" ":!*.md" | exit 0, 0 matches | git
- ISC-11 | integration | bats test/eap-tenant-routing.bats | exit 0, 100% pass | bats
- ISC-12 | integration | deliberate mutation check script | exit non-zero on mutation | bash

## Features
- Branch Integration | Merge feat/sldc-p3-1 and feat/sldc-p3-2 | ISC-1 | None | false
- Hash Vector Certification | Verify derivation matrix across Go/Py/TS | ISC-2, ISC-3, ISC-4, ISC-5 | Branch Integration | true
- Gateway & Route Verification | Deploy & test HTTPRoute + Envoy filter | ISC-6, ISC-7, ISC-8, ISC-9, ISC-11 | Branch Integration | false
- Typo Zero-Tolerance Audit | Enforce repository hygiene | ISC-10 | Branch Integration | true
- Mutation & Evidence | Run falsification and generate artifacts | ISC-12 | Gateway & Route Verification | false

## Decisions
- 2026-09-30: Initialized Phase 3 Governance gate verification in project ISA.

## Changelog
- Conjectured: Merging feat/sldc-p3-1 and feat/sldc-p3-2 will cleanly align tenant hash generation and Gateway API routing.
- Refuted by: N/A.
- Learned: Both feature branches are fully compatible and introduce disjoint components.
- Criterion now: ISC-1 verified upon merge.

## Verification
Pending phase execution.
