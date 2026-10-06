---
tags:
  - enhancement-proposals
  - signalloom
  - ci
  - gcp-lanes
  - kusari
date: 2026-10-06
status: Signed off by AJM 2026-10-06. Amended the same day with AJM decisions and council corrections. Cards not yet created.
author: Signal Loom Architecture Team (sensai-kusari-demo)
shortcode: EAPCI
repository: /home/andy/src/cp/osramp-demo
integration: integration/eapci-v0.1.0 (to be cut from feat/signal-loop-and-bootstrap-refactor at sign-off)
updated: 2026-10-06T12:50
---

# Proposal — Signal Loom EAP CI Lane and Demo Environment Redeploy (2026-Q4)

## Executive Summary

> CI does not test what we demo. The nightly `signalloom-ci` VM resets to
> `origin/main` (`scripts/ci/vm-pipeline.sh:154`). That ref is 4,626 commits behind
> `feat/signal-loop-and-bootstrap-refactor`, so none of the EAP, SLAWS or Kusari
> work runs in CI. The four GCP lanes (`demo-1`, `demo-2`, `ci-1`, `ci-2`) were
> last recorded on 2026-08-21, and the Kusari pilot lane (ratified decision D1)
> does not exist. This mission moves CI onto lane `ci-1`, pinned to a named ref,
> with the EAP legs the demo depends on. It repurposes lane `demo-2` as the Kusari
> pilot, published at the salted EAP endpoint `sl-eap-4b53ab6b` with
> `ACT_ENABLED=false` (K8). It redeploys `demo-1` from the feature branch. GitHub
> Actions run nothing for this branch: every deploy is local.

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
- **The pilot endpoint must satisfy the salted EAP contract.** EAP routing enforces `^sl-eap-[a-f0-9]{8}$` (`environment_routing.py:46`). SLED teardown severs routes by `signalloom.io/eap-hash` and `sl-eap-<hash>` hostnames (`environment_teardown.py:213-222`). `derive_customer_hash("kusari")` under salt `signalloom-eap-salt-2026-q3` is `4b53ab6b` (pinned in `test/tenant-hash-vectors.bats`), so the pilot publishes as `sl-eap-4b53ab6b.taild4da3.ts.net`.
- **`ACT_ENABLED` does not exist.** The stub registers `/act` unconditionally (`kusari-agent/main.go:569-571`), so the flag needs a code gate, not only an env var.
- **Lane records are stale.** All four `deploy/gcp/*.handoff.json` files date from 2026-08-21.

## 2. Out of Scope

- Deleting the `signalloom-ci` VM or anything else in `cp-dev-ajm`, and the nightly schedule on `main`. That schedule runs from the default branch, which this mission does not touch. VM deletion and `gh workflow disable` on `main` are AJM's actions.
- A fifth lane, a new lane kind, widening the lane-key regex, and any platform terraform apply. The regex is enforced in about nine places (`Makefile:2404`, terraform `env-contract` rules 01-03, the identity, edge and compute modules, `demo-up.sh:722`, `node-doctor.sh:408`, `where.sh:143`). The pilot reuses lane key `demo-2` (AJM 2026-10-06), whose service account and quota already exist. `CPUS_ALL_REGIONS` is 32 and the four lanes use all of it.
- Tetragon, in any lane. AJM decision 2026-10-06: Tetragon is never used. Runtime syscall detection is the warden's in-sentinel eBPF.
- Merging feat into `main`.
- Changing SLEA (on-demand EAP environment routing, owned by sensai-eap) or SLAWS P5 (owned by sensai-sltm).
- Production (GKE) deployment.

## 3. Constraints

- `gcloud` fails to load inside the agent sandbox ("gcloud failed to load", 2026-10-06 12:45). AJM lifts the sandbox restriction before P2. Every `gcp-tf-*` target and `doctor-node` need gcloud plus impersonation (`Makefile:2451`). P2-PRE gates on it.
- Lane bring-up spends GCP money in `sl-port-over-sandbox` and replaces lane VMs. This is the only external side effect. It is limited to `ci-1`, `demo-1` and `demo-2`, which is repurposed as the pilot. AJM approved destroying the current `demo-2` deployment. `ci-2` is untouched.
- `deploy/gcp/sl-port-over-sandbox.tfvars` and the hand-off files are gitignored (`.gitignore:138,151`). Cards commit the example tfvars and code. The live tfvars edit for `demo-2` (labels `tier=pilot`, hostname `sl-eap-4b53ab6b`, `act_enabled=false`) is an operator step recorded in P2-PRE.
- P2 commands carry `TF_STATE_BUCKET` and `GCP_TF_VAR_FILE`. `gcp-tf-surfaces-report` takes `LANES='ci-1 demo-2 demo-1'` and a short SHA in `COMMIT=`. Each lane needs `gcp-tf-test-both` for its tailnet receipt.
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
- P2 only: `make gcp-tf-surfaces-report COMMIT=<integration tip>`, with zero STALE lanes among `ci-1`, `demo-2` and `demo-1`.

## Appendix

### Spec: Shared Patterns

- **Lane identity.** Lane keys stay `^(demo|ci)-[1-9][0-9]*$`. The pilot is a profile on `demo-2` (hostname, labels, `act_enabled`), never a new key.
- **No GitHub CI for this branch.** Every workflow file on this branch is manual-only (`workflow_dispatch` or `workflow_call`).
- **Ref pinning.** Every lane deploy names its ref (`GCP_TF_DEMO_REF`). It deploys a clean worktree of that ref and records the SHA in the hand-off file. "Whatever HEAD is" is an error.
- **Tests.**
  - Tier 1 is bats or Go with mocks and fixtures, with no GCP and no cluster.
  - Tier 2 is the live lane run in P2, evidenced by the hand-off JSON and `surfaces-report`.
  - Mutation proofs restore from explicit backups, never from the index.
- **Anti-patterns.**
  - A step that "succeeds" at the wrong thing (`INCIDENTS-2026-08.md:184-195`).
  - Parallel lane runs.
  - Shipping a dirty tree with `GCP_TF_DEMO_ALLOW_DIRTY=1`.
  - Any reference to Tetragon, including the existing Tetragon test in `demo-pipeline.sh`.
  - A stage that passes on a bats `# skip`. The Kusari live tier skips without `KUSARI_LIVE=1`.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; context-mode | Baseline engineer | S | 45m | antigravity | Prove the harness, the integration branch and the four offline acceptance commands at the cut SHA. |
| P1-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | File:line map of the ENV check, the tfvars lane block, the `demo-up.sh` payload, `demo-pipeline.sh` test stages and the CI workflow; post lane names to chat for the SLEA collision check. |
| P1-1 | context-mode; Hardening | Platform engineer | M | 120m | antigravity | Per-lane `act_enabled` (default true; false only for the pilot profile) carried to the stub, plus a code gate on `/act` in `kusari-agent`; pilot profile for `demo-2` in the example tfvars. No regex or lane-kind change. |
| P1-2 | context-mode | Platform engineer | M | 120m | antigravity | `GCP_TF_DEMO_REF`: deploy a clean worktree of a named ref; `RUN_COMMIT` and the hand-off record that ref's short SHA and survive `gcp-tf-handoff` regeneration; refuse an implicit HEAD. |
| P1-3 | context-mode; ripwire | Test/CI engineer | L | 180m | antigravity | EAP stages in `demo-pipeline.sh` for `ci` lanes: `scripts/dual-cluster-up.sh`, `remote-tenant-lab.sh --load-kind-image`, `test-kusari-e2e`, Kusari live tier (fails on any skip), `slaws-acceptance.sh`, `test-eap-offline`; dual-lane allowlist entries. |
| P1-4 | context-mode | CI engineer | S | 60m | antigravity | Make every workflow on this branch manual-only (remove `pull_request`, `push` and `schedule` triggers); update `test/eap-pr-workflow.bats`; record the pre-existing TFID digest failure. No edits to `vm-pipeline.sh`. |
| P1-GOV | ajm-auto-kanban | Governor | M | 120m | antigravity | Merge P1 cards in order, run the four offline acceptance commands twice, record errata. |
| P2-PRE | context-mode | Pre-flight analyst | S | 45m | antigravity | Gate: gcloud loads, impersonation works, tailnet up, state bucket reachable. Any failure stops P2 and reports. |
| P2-1 | context-mode | Lane operator | M | 180m | antigravity | Bring up `ci-1` at the integration tip and run the EAP legs; collect the hand-off and test evidence. |
| P2-2 | context-mode | Lane operator | M | 180m | antigravity | Bring up `demo-2` as the Kusari pilot (`sl-eap-4b53ab6b`, `ACT_ENABLED=false`); run the onboarding smoke from `docs/EAP/onboarding.md`. |
| P2-3 | context-mode | Lane operator | M | 180m | antigravity | Redeploy `demo-1` at the integration tip; refresh hand-offs; `surfaces-report` over `ci-1 demo-2 demo-1`. |
| P2-GOV | ajm-auto-kanban | Governor | S | 90m | antigravity | Reconcile P2 evidence, confirm zero STALE lanes, close errata, request AJM final approval. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | baseline | On `integration/eapci-v0.1.0` at the cut SHA run `make test-eap-offline`, `make test-kusari-e2e`, `scripts/slaws-acceptance.sh /tmp/eapci-acceptance`, `make docs-lint`; `kanban-check.sh doctor`. | — | Four commands rc 0; totals in errata | S | antigravity | — | — | — | — | — |
| P1-PRE | preflight | File:line table for `Makefile:2397-2401` ENV check, `deploy/gcp/sl-port-over-sandbox.tfvars` lane block, `demo-up.sh:1068-1130` payload, `demo-pipeline.sh` test stages (around 838-851, 1062), `signalloom-ci.yaml:19-32`; name the exact edits for P1-1..P1-4; post lane names to `/tmp/chat.jsonl`. | P0 | Table in errata; no code change | S | antigravity | — | — | — | — | — |
| P1-1 | implementation | Add lane key `act_enabled` (default true) to the lane schema and example tfvars, carried to the demo environment as `ACT_ENABLED`; add a pilot profile for `demo-2` to the example tfvars (labels `tier=pilot`, hostname `sl-eap-4b53ab6b`, `act_enabled=false`); gate `/act` route registration in `d2-signalloom/apps/kusari-agent/main.go` (569-571) on `ACT_ENABLED`. | P1-PRE | Go test: `/act/*` answers 404 with `ACT_ENABLED=false` and 200 with true; bats: rendered demo env for an `act_enabled=false` lane has `ACT_ENABLED=false` and for others `true`; `terraform validate`; hostname matches `^sl-eap-[a-f0-9]{8}$` | M | antigravity | — | — | — | — | — |
| P1-2 | implementation | `GCP_TF_DEMO_REF=<ref>`: build the payload from a clean worktree of that ref; set `RUN_COMMIT` (`demo-up.sh:2049`) from that ref's short SHA; write `source_ref` and `source_sha` to the hand-off and keep them through `gcp-tf-handoff` regeneration; refuse to run with no ref unless `GCP_TF_DEMO_REF=HEAD` is explicit. | P1-PRE | bats with stubbed git and gcloud: payload SHA equals the ref SHA; a dirty principal tree does not change it; `source_sha` survives a regenerated hand-off; missing ref fails with a named error | M | antigravity | — | — | — | — | — |
| P1-3 | implementation | In `demo-pipeline.sh`, for `ci` lanes add stages: `scripts/dual-cluster-up.sh`, `scripts/remote-tenant-lab.sh --load-kind-image`, `make test-kusari-e2e`, `KUSARI_LIVE=1 bats test/kusari-e2e-live.bats` (stage fails on any `# skip`), `scripts/slaws-acceptance.sh`, `make test-eap-offline`; each stage records its rc; add the dual-lane allowlist entries `terraform-dual-lane-registration.bats` needs. | P1-PRE | bats with a stub runner: `ci` lanes run all six in order, `demo` lanes none; a failing or skipping stage fails the pipeline by name; dual-lane registration test green | L | antigravity | — | — | — | — | — |
| P1-4 | implementation | Make every workflow under `.github/workflows/` on this branch manual-only: remove `pull_request`, `push` and `schedule` triggers, keep `workflow_dispatch` and `workflow_call`; update `test/eap-pr-workflow.bats` to assert the manual-only contract; record (do not fix) the pre-existing TFID digest failure for `vm-pipeline.sh` and `ci-lock.sh`. | P1-PRE | A bats test asserts no workflow on the branch has `pull_request`, `push` or `schedule`; `eap-pr-workflow.bats` green; YAML parses (`yq`); docs-lint clean | S | antigravity | — | — | — | — | — |
| P1-GOV | governor | Merge P1-1..P1-4 in order into `integration/eapci-v0.1.0`; run the four §5 offline commands twice with identical totals; append errata. | P1-1, P1-2, P1-3, P1-4 | Two identical acceptance runs; errata complete | M | antigravity | — | — | — | — | — |
| P2-PRE | preflight | Gate: `gcloud --version` loads; impersonation check (`gcp_tf_require_impersonation`); `tailscale status` up; state bucket readable; `TF_STATE_BUCKET` and `GCP_TF_VAR_FILE` set; the operator's live tfvars has the `demo-2` pilot profile. Stop and report on any failure. | P1-GOV | Six checks recorded in errata | S | antigravity | — | — | — | — | — |
| P2-1 | implementation | `make gcp-tf-up ENV=ci-1`, `make gcp-tf-demo-up ENV=ci-1 GCP_TF_DEMO_REF=integration/eapci-v0.1.0`, `make doctor-node ENV=ci-1`, `make gcp-tf-test-both ENV=ci-1`; collect the P1-3 stage results. | P2-PRE | Hand-off `source_sha` equals the integration tip short SHA; all six EAP stages rc 0 with zero skips; tailnet receipt present | M | antigravity | — | — | — | — | — |
| P2-2 | implementation | The same four targets for `ENV=demo-2` (destroying its current deployment, approved by AJM), deployed as the Kusari pilot at `sl-eap-4b53ab6b.taild4da3.ts.net`; run the onboarding smoke (`docs/EAP/onboarding.md` §1-§5). | P2-1 | Hand-off SHA matches; `kubectl -n fe-signalloom-agents get deploy agent-kusari -o yaml` shows `ACT_ENABLED=false`; `/act/read-passwd` answers 404; the endpoint resolves on the tailnet; smoke transcript | M | antigravity | — | — | — | — | — |
| P2-3 | implementation | The same four targets for `ENV=demo-1` at the integration tip; then `make gcp-tf-surfaces-report LANES='ci-1 demo-2 demo-1' COMMIT=<short tip SHA recorded at P2-PRE>`. | P2-2 | Zero STALE and zero MISSING across the three lanes; hand-offs dated today; `ci-2` untouched | M | antigravity | — | — | — | — | — |
| P2-GOV | governor | Reconcile P2 evidence; confirm `ci-2` untouched; close errata; request AJM final approval. | P2-1, P2-2, P2-3 | Errata complete; surfaces-report attached | S | antigravity | — | — | — | — | — |

### Spec: Errata

_Cards append `#### Errata — EAPCI-<ID>` blocks here in delivery order. Nothing has run._

#### Amendment — 2026-10-06 12:42 +0100 (before any card ran)

- AJM decision: the Kusari pilot repurposes lane `demo-2`. No fifth lane, no lane-kind or regex change, no quota request.
- AJM decision: no GitHub Actions jobs for this branch. Deploys are local only.
- Adopted from an unannounced external edit: the pilot endpoint is the salted EAP host `sl-eap-4b53ab6b`. That edit's claim that gcloud works was false inside the agent sandbox at 12:45. Its uncommitted `Makefile` and `test/terraform-make-contract.bats` changes admitting `pilot-kusari` in the main checkout are not part of this mission.
- Council corrections: `dual-cluster-up.sh` creates the second cluster; `RUN_COMMIT` and hand-off regeneration; `surfaces-report` needs `LANES` and a short SHA; tailnet receipts need `gcp-tf-test-both`; `ACT_ENABLED` needs a code gate; `-n fe-signalloom-agents`; live tier must fail on skip; TFID digest test already red at `c7b09517`.
