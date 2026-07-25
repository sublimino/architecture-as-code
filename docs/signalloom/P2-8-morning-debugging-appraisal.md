# P2-8 morning debugging/status appraisal

<!-- machine-tag: signalloom-p2-8-appraisal -->
<!-- appraisal-state: in-progress -->
<!-- generated-at: 2026-07-26T00:38:32+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- baseline-sha: d08e00f8b7f28dde061330e036c9cc2e15f354d3 -->

This is the repository-local errata appraisal for P2-8.  It deliberately does
not modify the Obsidian proposal (`docs/plans/d2-bao-integration.md`),
`board.json`, another worktree, or any external environment.

## Qualified preflight evidence

| Machine tag | Status | Exact command | Result | Durable evidence/artifact |
| --- | --- | --- | --- | --- |
| `P2-8-CONTRACT-001` | PASS | `env LC_ALL=C LANG=C make signalloom-check` | Delivery contract, deployment guard, four git roots, and six required paths passed. | `docs/signalloom/delivery-contract.json`; `scripts/signalloom-contract-check.sh`; `scripts/signalloom-preflight.sh` |
| `P2-8-CONFIG-001` | PASS | `env LC_ALL=C LANG=C make demo-signalloom-test-config` | Static topology/dependency checks and 9 Bats assertions passed. | `d2-signalloom/test/validate-topology.sh`; `d2-signalloom/test/validate-dependencies.sh`; `d2-signalloom/test/{bootstrap,portal-package}.bats` |
| `P2-8-LIFECYCLE-001` | PASS | `env LC_ALL=C LANG=C make test-demo-lifecycle` | 4/4: aliases exist; purge blocks retained consumers and unavailable consumer queries; force is explicit. | `test/demo-lifecycle.bats`; `scripts/demo-lifecycle.sh` |
| `P2-8-FLUX-HARNESS-001` | PASS | `env LC_ALL=C LANG=C bats test/signalloom-flux-integration.bats` | 3/3: local/GitHub publication/signing declarations, local Cosign verification, and Bao → infra → portal wait order. | `test/signalloom-flux-integration.bats` |

All commands above exited `0` from this worktree.  Their command output is
also retained in this P2-8 agent session's context-mode execution record.

## Runtime qualification and next action

<!-- machine-tag: P2-8-RUNTIME-QUALIFICATION -->

At `2026-07-26T00:37:44+01:00`, Docker `29.5.2`, Kind, kubectl, Flux
`v2.9.3`, Bats `1.13.0`, make, and jq were available, but `kind get clusters`
reported **no Kind clusters** and kubectl had no current context.  Therefore
no real-cluster reconciliation, application request, or teardown has yet been
claimed.  The lifecycle Bats suite is dynamic against its temporary fake
kubectl boundary; it is not equivalent to a real Kind/Flux walkthrough.

The clean integration baseline is recorded above.  This appraisal's first
commit supplies the requested committed qualified-evidence checkpoint before
any local shared-cluster mutation is considered.  Runtime work must remain
local-only, avoid teardown/purge, and capture its result in a later append.

## Robustness assessment and debugging order

1. **First:** create/qualify a disposable local Kind context, then run
   `make cluster-up registry flux-bootstrap`; preserve command output and
   inspect Flux `ResourceSet`/`Kustomization` readiness before invoking a
   Signal Loom lifecycle action.
2. **Second:** run `make flux-test`, `make demo-signalloom-up`, and
   `make demo-signalloom-test`; capture `kubectl get` and `kubectl describe`
   for the five asserted Kustomizations plus relevant Flux events on failure.
3. **Third:** run the application walkthrough only after ready reconciliation;
   retain its request/response and pod logs.  Do not run `*-down`,
   `stack-purge`, `cluster-down`, or `teardown` as P2-8 validation.
4. The current harness is strong for ordering, declaration, and fail-closed
   deletion semantics, but it does not prove OCI pull, Cosign verification,
   ResourceSet expansion, workload readiness, or a real request path.  Those
   are the highest-priority runtime gaps.
