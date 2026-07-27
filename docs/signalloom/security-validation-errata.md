# Signal Loom bounded security validation errata

<!-- machine-tag: SIGNALLOOM-SECURITY-VALIDATION-2026-07-27T09:31:00+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.5.0 -->
<!-- scope: repository-local-scanners-and-bounded-local-target-discovery-only -->
<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->

This record is a fail-closed validation result for the current repository
revision. It neither authorises a release nor claims hosted, production, or
external-target security evidence. No board record, remote, pull request, or
other worktree was changed.

## Threat model

`docs/signalloom/demo-to-hosted-threat-model.md` identifies browser/API,
storage, fake-provider egress, secrets, runtime hardening, and supply-chain
trust boundaries. The current local demo retains hosted exit criteria for
tenant isolation, private report access, gateway-only ingress, approved egress,
and immutable candidate verification. Those open controls remain promotion
blockers.

## Bounded execution evidence

| Gate | Command or bounded precondition | Exit | Result |
| --- | --- | --- | --- |
| Static D2 contracts | `env LC_ALL=C LANG=C make -C d2-signalloom test` | 0 | Pass: 29 deterministic topology, dependency, identity, gateway, and policy assertions. |
| Secure defaults and egress fixtures | `env LC_ALL=C LANG=C bats d2-signalloom/test/least-privilege.bats test/signalloom-test-1-harness.bats` | 0 | Pass: nine static harness assertions retain default-deny policy and runtime egress-negative coverage. |
| Release contract | `env LC_ALL=C LANG=C make signalloom-security-release-pack-check && env LC_ALL=C LANG=C make signalloom-contract-check` | 0 | Pass: release evidence remains fail-closed and candidate-only. |
| SAST | `semgrep scan --config=auto --offline --error d2-signalloom` | 2 | Fail: installed Semgrep does not support the requested offline mode; no approved local ruleset was available. |
| SCA and misconfiguration | `trivy fs --offline-scan --skip-db-update --exit-code 1 --severity HIGH,CRITICAL --scanners vuln,secret,misconfig d2-signalloom` | 1 | Fail: HIGH `DS-0002` in `d2-signalloom/proof-helper.Dockerfile` requires a non-root `USER` instruction. |
| Secret scan | `trufflehog filesystem --no-update --fail d2-signalloom` | 183 | Fail: three unverified PostgreSQL connection-string detections require triage or an approved non-secret fixture policy. |
| DAST | `kubectl -n fe-signalloom get deployment fe-signalloom` | 1 | Blocked: no local `fe-signalloom` deployment exists; no target was scanned. |
| Egress denial | `d2-signalloom/test/test-1-runtime.bats` runtime target precondition | 1 | Blocked: same missing local workload prevents its bounded external-egress denial probe. |
| SBOM | `syft dir:d2-signalloom -o spdx-json` | 127 | Fail: Syft is unavailable locally; no SPDX JSON artifact was generated. |
| Signature, provenance, digest | Immutable candidate digest precondition | 1 | Blocked: no candidate `repository@sha256:...` exists to verify through Cosign, SBOM, or provenance. |

## Decision

The deterministic static controls are useful regression evidence but do not replace failed, blocked, or missing candidate-bound security evidence.
The correct disposition is `status=fail proceed=no blocking_drift=yes` until an
approved local SAST ruleset, SCA remediation or accepted exception, secret
triage, a disposable local DAST target, Syft-generated SPDX artifact, and a
single immutable candidate digest with matching signature and SLSA provenance
are available.
