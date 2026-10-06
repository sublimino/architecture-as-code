---
tags:
  - enhancement-proposals
  - signalloom
  - ci
  - gcp-lanes
  - kusari
date: 2026-10-06
status: DRAFT, awaiting AJM sign-off. No work has started. No cards, branches, worktrees or cron exist.
author: Signal Loom Architecture Team (sensai-kusari-demo)
shortcode: EAPCI
repository: /home/andy/src/cp/osramp-demo
integration: integration/eapci-v0.1.0 (to be cut from feat/signal-loop-and-bootstrap-refactor at sign-off)
updated: 2026-10-06T12:20
---

# Proposal — Signal Loom EAP CI Lane and Demo Environment Redeploy (2026-Q4)

## Executive Summary

> CI does not test what we demo. The nightly `signalloom-ci` VM resets to
> `origin/main` (`scripts/ci/vm-pipeline.sh:154`). That ref is 4,626 commits behind
> `feat/signal-loop-and-bootstrap-refactor`, so none of the EAP, SLAWS or Kusari
> work runs in CI. The four GCP lanes (`demo-1`, `demo-2`, `ci-1`, `ci-2`) were
> last recorded on 2026-08-21, and the Kusari pilot lane `sl-pilot-kusari`
> (ratified decision D1) does not exist. This mission moves CI onto lane `ci-1`,
> pinned to a named ref, with the EAP legs the demo depends on. It adds the pilot
> lane with `ACT_ENABLED=false` (K8) and redeploys `demo-1` from the feature
> branch.

## 1. Problem

- **CI tests the wrong branch.**
  - The nightly workflow `.github/workflows/signalloom-ci.yaml:19-32` drives VM `signalloom-ci` in project `cp-dev-ajm`.
  - The VM runs `git reset --hard origin/main && git clean -fdx` before the pipeline.
- **No CI run exercises the EAP shape.** The pipelines run only the offline dual-cluster tests (`vm-pipeline.sh:805-809`, `demo-pipeline.sh:838-851`). Nothing in them exercises:
  - the second cluster
  - the warden `remote-tenant` overlay
  - `scripts/remote-tenant-lab.sh`
  - `make test-kusari-e2e`
  - the Kusari live tier
  - SLAWS acceptance
  - the awslogs fixture overlay.
- **Lanes deploy whatever the operator's checkout holds.** `scripts/gcp-tf/demo-up.sh:1068-1130` builds the payload with `git archive HEAD`, and nothing pins a ref.
- **`sl-pilot-kusari` cannot be named today.** `ENV` must match `^(demo|ci)-[1-9][0-9]*$` (`Makefile:2397-2401`). `ACT_ENABLED` does not exist in the repo.
- **Lane records are stale.** All four `deploy/gcp/*.handoff.json` files date from 2026-08-21.

## 2. Out of Scope

- Deleting the `signalloom-ci` VM or anything else in `cp-dev-ajm`. Retirement here means disabling the schedule. VM deletion is AJM's action, outside this mission.
- Tetragon, in any lane. AJM decision 2026-10-06: Tetragon is never used. Runtime syscall detection is the warden's in-sentinel eBPF.
- Merging feat into `main`.
- Changing SLEA (on-demand EAP environment routing, owned by sensai-eap) or SLAWS P5 (owned by sensai-sltm).
- Production (GKE) deployment.

## 3. Constraints

- The local `gcloud` is broken ("gcloud failed to load … Python 3.10-3.14"). Every `gcp-tf-*` target and `doctor-node` need it plus impersonation (`Makefile:2451`). **P2 cannot start until AJM repairs gcloud.** P2-PRE gates on it.
- Lane bring-up spends GCP money in `sl-port-over-sandbox` and replaces lane VMs. This is the only external side effect, and it is limited to lanes `ci-1`, `demo-1` and the new `pilot-kusari`. `ci-2` and `demo-2` are untouched.
- Parallel lanes share `.terraform.lock.hcl` and the AFM archive path (`INCIDENTS-2026-08.md:75`). P2 runs lanes sequentially.
- Every lane deploy runs from a clean worktree of the pinned ref (`make gcp-tf-worktree-bootstrap`), never from the principal checkout.

## 4. Coordination

- **sensai-eap (SLEA).** Overlaps on Tailscale and environment routing. P1-PRE posts the planned lane names to `/tmp/chat.jsonl` and records any collision.
- **sensai-sltm (SLAWS P5).** Owns `scripts/slaws-acceptance.sh` and the CI parity check (`b9177c3f`). This mission calls them and does not edit them.

## 5. Acceptance

- `make test-eap-offline`
- `make test-kusari-e2e`
- `scripts/slaws-acceptance.sh /tmp/eapci-acceptance`
- `make docs-lint`
- P2 only: `make gcp-tf-surfaces-report COMMIT=<integration tip>`, with zero STALE lanes among `ci-1`, `demo-1` and `pilot-kusari`.

## Appendix

### Spec: Shared Patterns

- **Lane identity.** A lane key is `<kind>-<suffix>`. P1-1 widens the `ENV` check to admit `pilot-kusari` and keeps every existing key valid. A bats test pins both.
- **Ref pinning.** Every lane deploy names its ref (`GCP_TF_DEMO_REF`). It deploys a clean worktree of that ref and records the SHA in the hand-off file. "Whatever HEAD is" is an error.
- **Tests.**
  - Tier 1 is bats or Go with mocks and fixtures, with no GCP and no cluster.
  - Tier 2 is the live lane run in P2, evidenced by the hand-off JSON and `surfaces-report`.
  - Mutation proofs restore from explicit backups, never from the index.
- **Anti-patterns.**
  - A step that "succeeds" at the wrong thing (`INCIDENTS-2026-08.md:184-195`).
  - Parallel lane runs.
  - Shipping a dirty tree with `GCP_TF_DEMO_ALLOW_DIRTY=1`.
  - Any reference to Tetragon.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; context-mode | Baseline engineer | S | 45m | antigravity | Prove the harness, the integration branch and the four offline acceptance commands at the cut SHA. |
| P1-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | File:line map of the ENV check, the tfvars lane block, the `demo-up.sh` payload, `demo-pipeline.sh` test stages and the CI workflow; post lane names to chat for the SLEA collision check. |
| P1-1 | context-mode; Hardening | Platform engineer | M | 120m | antigravity | Widen ENV validation, add the `pilot-kusari` tfvars lane, plumb `ACT_ENABLED` (default false for the pilot) from tfvars to the demo environment. |
| P1-2 | context-mode | Platform engineer | M | 120m | antigravity | `GCP_TF_DEMO_REF`: deploy a clean worktree of a named ref, record the SHA in the hand-off, refuse an implicit HEAD. |
| P1-3 | context-mode; ripwire | Test/CI engineer | L | 180m | antigravity | Add the EAP legs to `demo-pipeline.sh` for `kind=ci` lanes: second kind cluster, `remote-tenant-lab.sh --load-kind-image`, `test-kusari-e2e`, the Kusari live tier, SLAWS acceptance, awslogs fixture overlay, `test-eap-offline`. |
| P1-4 | context-mode | CI engineer | S | 60m | antigravity | Remove the nightly schedule from `signalloom-ci.yaml`; add a `workflow_dispatch` that drives the `ci-1` lane at a named ref; deprecation header on `vm-pipeline.sh`. No VM deletion. |
| P1-GOV | ajm-auto-kanban | Governor | M | 120m | antigravity | Merge P1 cards in order, run the four offline acceptance commands twice, record errata. |
| P2-PRE | context-mode | Pre-flight analyst | S | 45m | antigravity | Gate: gcloud loads, impersonation works, tailnet up, state bucket reachable. Any failure stops P2 and reports. |
| P2-1 | context-mode | Lane operator | M | 180m | antigravity | Bring up `ci-1` at the integration tip and run the EAP legs; collect the hand-off and test evidence. |
| P2-2 | context-mode | Lane operator | M | 180m | antigravity | Bring up `pilot-kusari` with `ACT_ENABLED=false`; run the Kusari onboarding smoke from `docs/EAP/onboarding.md`. |
| P2-3 | context-mode | Lane operator | M | 180m | antigravity | Redeploy `demo-1` at the integration tip; refresh the hand-off records; `surfaces-report` across the three lanes. |
| P2-GOV | ajm-auto-kanban | Governor | S | 90m | antigravity | Reconcile P2 evidence, confirm zero STALE lanes, close errata, request AJM final approval. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | baseline | On `integration/eapci-v0.1.0` at the cut SHA run `make test-eap-offline`, `make test-kusari-e2e`, `scripts/slaws-acceptance.sh /tmp/eapci-acceptance`, `make docs-lint`; `kanban-check.sh doctor`. | — | Four commands rc 0; totals in errata | S | antigravity | — | — | — | — | — |
| P1-PRE | preflight | File:line table for `Makefile:2397-2401` ENV check, `deploy/gcp/sl-port-over-sandbox.tfvars` lane block, `demo-up.sh:1068-1130` payload, `demo-pipeline.sh` test stages (around 838-851, 1062), `signalloom-ci.yaml:19-32`; name the exact edits for P1-1..P1-4; post lane names to `/tmp/chat.jsonl`. | P0 | Table in errata; no code change | S | antigravity | — | — | — | — | — |
| P1-1 | implementation | Admit `pilot-kusari` in the ENV check; add the `pilot-kusari` tfvars lane (us-east4-a, n2-standard-8, labels `tier=pilot`); add a lane key `act_enabled` (default false) carried to the demo environment as `ACT_ENABLED`. | P1-PRE | bats: ENV accepts `demo-1`, `ci-2`, `pilot-kusari` and rejects `prod-1`, `pilot`; `terraform validate`; rendered demo env for `pilot-kusari` has `ACT_ENABLED=false` | M | antigravity | — | — | — | — | — |
| P1-2 | implementation | `GCP_TF_DEMO_REF=<ref>`: build the payload from a clean worktree of that ref; write `source_ref` and `source_sha` to the hand-off JSON; refuse to run with no ref set unless `GCP_TF_DEMO_REF=HEAD` is explicit. | P1-PRE | bats with stubbed git and gcloud: payload SHA equals the ref SHA; a dirty principal tree does not change the payload; missing ref fails with a named error | M | antigravity | — | — | — | — | — |
| P1-3 | implementation | In `demo-pipeline.sh`, for `kind=ci` lanes add the stages: second kind cluster (`scripts/p2-dualcluster-preflight.sh`), `scripts/remote-tenant-lab.sh --load-kind-image`, `make test-kusari-e2e`, `KUSARI_LIVE=1 bats test/kusari-e2e-live.bats`, `scripts/slaws-acceptance.sh`, awslogs fixture overlay, `make test-eap-offline`; each stage writes its rc to the collected results. | P1-PRE | bats with a stub runner: the stage list for `kind=ci` contains all seven in order and for `kind=demo` contains none; a failing stage fails the pipeline with its name | L | antigravity | — | — | — | — | — |
| P1-4 | implementation | Remove `schedule:` from `.github/workflows/signalloom-ci.yaml`; add a `workflow_dispatch` input `ref` that drives the `ci-1` lane through P1-2's `GCP_TF_DEMO_REF`; add a deprecation header to `scripts/ci/vm-pipeline.sh`. | P1-PRE | `actionlint` clean; test asserts no `schedule:` key; docs-lint clean | S | antigravity | — | — | — | — | — |
| P1-GOV | governor | Merge P1-1..P1-4 in order into `integration/eapci-v0.1.0`; run the four §5 offline commands twice with identical totals; append errata. | P1-1, P1-2, P1-3, P1-4 | Two identical acceptance runs; errata complete | M | antigravity | — | — | — | — | — |
| P2-PRE | preflight | Gate: `gcloud --version` loads; impersonation check (`gcp_tf_require_impersonation`); `tailscale status` up; state bucket readable. Stop and report on any failure. | P1-GOV | Four checks recorded in errata | S | antigravity | — | — | — | — | — |
| P2-1 | implementation | `make gcp-tf-up ENV=ci-1`, `make gcp-tf-demo-up ENV=ci-1 GCP_TF_DEMO_REF=integration/eapci-v0.1.0`, `make doctor-node ENV=ci-1`; collect the stage results from P1-3. | P2-PRE | Hand-off `source_sha` equals the integration tip; all seven EAP stages rc 0 | M | antigravity | — | — | — | — | — |
| P2-2 | implementation | Same three targets for `ENV=pilot-kusari`; confirm `ACT_ENABLED=false` on the stub; run the onboarding smoke (`docs/EAP/onboarding.md` §1-§5). | P2-1 | Hand-off SHA matches; `kubectl get deploy agent-kusari -o yaml` shows `ACT_ENABLED=false`; smoke transcript | M | antigravity | — | — | — | — | — |
| P2-3 | implementation | Same three targets for `ENV=demo-1` at the integration tip; then `make gcp-tf-surfaces-report COMMIT=<tip>`. | P2-2 | Zero STALE among `ci-1`, `pilot-kusari`, `demo-1`; hand-off records dated today | M | antigravity | — | — | — | — | — |
| P2-GOV | governor | Reconcile P2 evidence; confirm `ci-2` and `demo-2` untouched; close errata; request AJM final approval. | P2-1, P2-2, P2-3 | Errata complete; surfaces-report attached | S | antigravity | — | — | — | — | — |

### Spec: Errata

_Cards append `#### Errata — EAPCI-<ID>` blocks here in delivery order. Nothing has run._
