# Historical Records, CI Evidence, Audits, and Proofs

This directory holds point-in-time certification artifacts, CI evidence bundles,
preflight proofs, and governance reports. These files record the output of past
verification runs.

The documentation linter ([`scripts/docs-lint.sh`](../../scripts/docs-lint.sh))
classifies [`docs/records/`](./) under the `records` tier. It checks links,
Markdown tables, and Mermaid diagrams, and skips living-prose style and
existence checks so historical paths and commands remain intact.

## Directory layout

| Subdirectory | Contents | Producer scripts |
|--------------|----------|------------------|
| [`ci-evidence/`](ci-evidence/) | SLDC, SLAAT, and SLAWS preflight manifests, governor certification JSONs, adversarial replay results, and permutation matrices | [`scripts/p1-sentinel-preflight.sh`](../../scripts/p1-sentinel-preflight.sh), [`scripts/p2-dualcluster-preflight.sh`](../../scripts/p2-dualcluster-preflight.sh), [`scripts/p3-tenant-preflight.sh`](../../scripts/p3-tenant-preflight.sh), [`scripts/verify-sldc-p0-baseline.sh`](../../scripts/verify-sldc-p0-baseline.sh), [`scripts/test-phase1-governor.sh`](../../scripts/test-phase1-governor.sh), [`scripts/test-phase2-governor.sh`](../../scripts/test-phase2-governor.sh), [`scripts/test-phase3-governor.sh`](../../scripts/test-phase3-governor.sh), [`scripts/final-governor-certification.sh`](../../scripts/final-governor-certification.sh), [`scripts/slaws-slaat-permutation-matrix.sh`](../../scripts/slaws-slaat-permutation-matrix.sh) |
| [`eap-evidence/`](eap-evidence/) | Signed EAP pilot containment bundles (`eap-kusari-containment.tar.gz`), detached SHA-256 signatures, cold-start supertest results, and Phase 6 teardown readiness reports | [`scripts/package-eap-evidence.sh`](../../scripts/package-eap-evidence.sh), [`scripts/verify-eap-evidence.sh`](../../scripts/verify-eap-evidence.sh), [`scripts/verify-teardown-prereqs.sh`](../../scripts/verify-teardown-prereqs.sh), [`scripts/super-test-adversarial.sh`](../../scripts/super-test-adversarial.sh) |
| [`preflight-proofs/`](preflight-proofs/) | Phase 1 and Phase 2 preflight and governance proof JSONs for OpenBao audit (`baoaudit`), cloud audit (`cloudaudit`), and eBPF network telemetry (`netebpf`) | [`scripts/cloudaudit-preflight.sh`](../../scripts/cloudaudit-preflight.sh), [`scripts/cloudaudit-p2-preflight.sh`](../../scripts/cloudaudit-p2-preflight.sh), [`scripts/baoaudit-preflight.sh`](../../scripts/baoaudit-preflight.sh), [`scripts/netebpf-preflight.sh`](../../scripts/netebpf-preflight.sh) |
| [`signalloom-proofs/`](signalloom-proofs/) | Point-in-time Markdown preflight and governor proofs for AMXO, SFDP, SLAC, SLCD, and SLDP delivery waves | Wave governor and preflight runs |

## Related record locations

- [`MEMORY/`](../../MEMORY/) and [`Plans/`](../../Plans/) stay at the repository
  root for active multi-agent task memory and execution plans.
- `.kanban-review-ledger.json`, `.kagent-preflight-proof.json`, and
  `.kpai-harness-verified.json` stay at the repository root because active gate
  suites inspect them in place.
- Runtime report directories (`reports/`, `.ci-runs/`, `.ci-state/`, and
  `evidence/`) are gitignored scratch outputs and are never committed.
