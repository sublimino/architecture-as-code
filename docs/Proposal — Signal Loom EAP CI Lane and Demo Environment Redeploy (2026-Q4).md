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
> pilot, published at the salted EAP endpoint `sl-eap-4b53ab6b`, with the `/act`
> stun demo enabled. It makes all kind data host-persistent. It redeploys `demo-1`
> from the feature branch. GitHub
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
- **The stun demo needs `/act`.** The stub's `/act/read-passwd`, `/act/read-shadow` and `/act/cpu-burn` routes (`kusari-agent/main.go:569-571`) trigger detection by the warden's in-sentinel eBPF, then the stun. AJM 2026-10-06: `/act` stays enabled on every lane, superseding playbook K8.
- **No kind data is host-persistent.** The running `kind-osramp` was built from `infra/kind/cluster-osramp.yaml`, which has no `extraMounts` for data. Postgres (hostPath `/var/local/signalloom-postgres-data`) and every `local-path` PVC (FrostDB `signal-store`, `spire-server-data`, `kagent-postgresql`) live in the node's anonymous Docker `/var` volume. A `kind delete cluster` or a scratch rebuild loses them. `scripts/create-kind-cluster.sh:132-136` mounts Postgres and the Zot cache from the host, but the dual-cluster path does not.
- **The observations route answers non-deterministically.** `QueryRange` in `store/frostdb.go:484` and `store/memory.go:31` has no ordering, and `scopeObservations` (`api/tenancy_grants.go:75-89`) truncates the unordered result to `limit`. Two identical back-to-back requests returned 18 different ids out of 100 (2026-10-06). Every reader of `GET /api/v1/observations` (dashboard via `signal_fusion.py`, `policy-engine/observations.go`, the live tests) can silently miss rows, and there is no cursor to page with.
- **Lane records are stale.** All four `deploy/gcp/*.handoff.json` files date from 2026-08-21.

## 2. Out of Scope

- Deleting the `signalloom-ci` VM or anything else in `cp-dev-ajm`, and the nightly schedule on `main`. That schedule runs from the default branch, which this mission does not touch. VM deletion and `gh workflow disable` on `main` are AJM's actions.
- A fifth lane, a new lane kind, widening the lane-key regex, and any platform terraform apply. The regex is enforced in about nine places (`Makefile:2404`, terraform `env-contract` rules 01-03, the identity, edge and compute modules, `demo-up.sh:722`, `node-doctor.sh:408`, `where.sh:143`). The pilot reuses lane key `demo-2` (AJM 2026-10-06), whose service account and quota already exist. `CPUS_ALL_REGIONS` is 32 and the four lanes use all of it.
- Tetragon, in any lane. AJM decision 2026-10-06: Tetragon is never used. Runtime syscall detection is the warden's in-sentinel eBPF. The wider removal (collector refactor, manifests, `test-tetragon*` targets, UI labels, the adversarial suite) is owned by the proposal *In-Sentinel eBPF Migration and Tetragon Deprecation (2026-Q4)*. This mission removes only the Tetragon suite from the two pipeline lists it edits.
- Merging feat into `main`.
- Changing SLEA (on-demand EAP environment routing, owned by sensai-eap) or SLAWS P5 (owned by sensai-sltm).
- Production (GKE) deployment.

## 3. Constraints

- `gcloud` fails to load inside the agent sandbox ("gcloud failed to load", 2026-10-06 12:45). AJM lifts the sandbox restriction before P2. Every `gcp-tf-*` target and `doctor-node` need gcloud plus impersonation (`Makefile:2451`). P2-PRE gates on it.
- Lane bring-up spends GCP money in `sl-port-over-sandbox` and replaces lane VMs. This is the only external side effect. It is limited to `ci-1`, `demo-1` and `demo-2`, which is repurposed as the pilot. AJM approved destroying the current `demo-2` deployment. `ci-2` is untouched.
- `deploy/gcp/sl-port-over-sandbox.tfvars` and the hand-off files are gitignored (`.gitignore:138,151`). Cards commit the example tfvars and code. The live tfvars edit for `demo-2` (labels `tier=pilot`, `tailscale_hostname` `sl-eap-4b53ab6b`) is an operator step recorded in P2-PRE.
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
- P2-4: Postgres row counts, FrostDB observation count and kagent DB rows are equal before and after a `kind delete cluster` and rebuild.
- Every lane: `kubectl get crd` lists nothing matching `tetragon`.
- `GET /api/v1/observations`: identical requests return identical rows in the same order, and cursor paging visits every row exactly once.
- P2 only: `make gcp-tf-surfaces-report COMMIT=<integration tip>`, with zero STALE lanes among `ci-1`, `demo-2` and `demo-1`.

## Appendix

### Spec: Shared Patterns

- **Lane identity.** Lane keys stay `^(demo|ci)-[1-9][0-9]*$`. The pilot is a profile on `demo-2` (`tailscale_hostname`, labels), never a new key.
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
  - Any new reference to Tetragon. P1-3 deletes the existing suite entry from both pipelines.
  - Cluster data inside the kind node's anonymous `/var` volume. Every data path is an `extraMount` from the host.
  - A stage that passes on a bats `# skip`. The Kusari live tier skips without `KUSARI_LIVE=1`.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; context-mode | Baseline engineer | S | 45m | antigravity | Prove the harness, the integration branch and the four offline acceptance commands at the cut SHA. |
| P1-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | File:line map of the ENV check, the tfvars lane block, the `demo-up.sh` payload, `demo-pipeline.sh` test stages and the CI workflow; post lane names to chat for the SLEA collision check. |
| P1-1 | context-mode; Hardening | Platform engineer | M | 120m | antigravity | Pilot profile for `demo-2`: `tailscale_hostname` override `sl-eap-4b53ab6b` (not `hostname`, which turns on public TLS), labels `tier=pilot`, in the example tfvars and lane schema. `/act` stays enabled. |
| P1-2 | context-mode | Platform engineer | M | 120m | antigravity | `GCP_TF_DEMO_REF`: deploy a clean worktree of a named ref; `RUN_COMMIT` and the hand-off record that ref's short SHA and survive `gcp-tf-handoff` regeneration; refuse an implicit HEAD. |
| P1-3 | context-mode; ripwire | Test/CI engineer | L | 180m | antigravity | EAP stages in `demo-pipeline.sh` for `ci` lanes (dual cluster, remote-tenant lab, Kusari offline and live, SLAWS, EAP offline); remove the Tetragon suite from `demo-pipeline.sh:820` and `vm-pipeline.sh:780` together. |
| P1-4 | context-mode | CI engineer | S | 60m | antigravity | Make every workflow on this branch manual-only (remove `pull_request`, `push` and `schedule` triggers); update `test/eap-pr-workflow.bats`; record the pre-existing TFID digest failure. No edits to `vm-pipeline.sh`. |
| P1-5 | context-mode; Hardening | Platform engineer | M | 150m | antigravity | Host-persistent kind data: `extraMounts` for Postgres, `local-path` PV storage and the Zot cache in `infra/kind/cluster-osramp.yaml` and the hub config, created by `dual-cluster-up.sh`; one source shared with `create-kind-cluster.sh`; a backup and restore script for node data. |
| P1-6 | context-mode; Hardening | Go platform engineer | L | 180m | antigravity | Deterministic observations API: total order `(timestamp DESC, id DESC)` applied in the GET handler before the limit, store and replay order unchanged; opaque cursor paging with an explicit truncation signal; consumers and the live tier moved to the cursor; plain-language API docs. |
| P1-GOV | ajm-auto-kanban | Governor | M | 120m | antigravity | Merge P1 cards in order, run the four offline acceptance commands twice, record errata. |
| P2-PRE | context-mode | Pre-flight analyst | S | 45m | antigravity | Gate: gcloud loads, impersonation works, tailnet up, state bucket reachable. Any failure stops P2 and reports. |
| P2-1 | context-mode | Lane operator | M | 180m | antigravity | Bring up `ci-1` at the integration tip and run the EAP legs; collect the hand-off and test evidence. |
| P2-2 | context-mode | Lane operator | M | 180m | antigravity | Bring up `demo-2` as the Kusari pilot (`sl-eap-4b53ab6b`); run the onboarding smoke and the `/act` stun chain. |
| P2-3 | context-mode | Lane operator | M | 180m | antigravity | Redeploy `demo-1` at the integration tip; refresh hand-offs; `surfaces-report` over `ci-1 demo-2 demo-1`. |
| P2-4 | context-mode | Platform operator | M | 180m | antigravity | Migrate local `kind-osramp` to host-persistent storage: declare on chat, back up, rebuild with the P1-5 mounts, restore, prove data survives a delete and rebuild. |
| P2-GOV | ajm-auto-kanban | Governor | S | 90m | antigravity | Reconcile P2 evidence, confirm zero STALE lanes, close errata, request AJM final approval. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | baseline | On `integration/eapci-v0.1.0` at the cut SHA run `make test-eap-offline`, `make test-kusari-e2e`, `scripts/slaws-acceptance.sh /tmp/eapci-acceptance`, `make docs-lint`; `kanban-check.sh doctor`. | — | Four commands rc 0; totals in errata | S | antigravity | — | — | — | — | — |
| P1-PRE | preflight | File:line table for `Makefile:2397-2401` ENV check, `deploy/gcp/sl-port-over-sandbox.tfvars` lane block, `demo-up.sh:1068-1130` payload, `demo-pipeline.sh` test stages (around 838-851, 1062), `signalloom-ci.yaml:19-32`; name the exact edits for P1-1..P1-4; post lane names to `/tmp/chat.jsonl`. | P0 | Table in errata; no code change | S | antigravity | — | — | — | — | — |
| P1-1 | implementation | Add an optional lane attribute `tailscale_hostname` to the `environments` object type (`env-contract/variables.tf`, a strict type that drops undeclared keys), carry it through the compute module (which hard-codes `sl-${environment_key}` at `compute/main.tf:175,213`) and the hand-off writer to `demo-up.sh:3384` and a pilot profile for `demo-2` in the example tfvars: labels `tier=pilot`, `tailscale_hostname = "sl-eap-4b53ab6b"`; do not set `hostname`, which enables public TLS (`edge/main.tf:34`). `/act` stays enabled on every lane. | P1-PRE | `terraform validate`; bats: the `demo-2` profile renders `tailscale_hostname` matching `^sl-eap-[a-f0-9]{8}$` and no `hostname`; other lanes unchanged | M | antigravity | — | — | — | — | — |
| P1-2 | implementation | `GCP_TF_DEMO_REF=<ref>`: build the payload from a clean worktree of that ref; set `RUN_COMMIT` (`demo-up.sh:2049`) from that ref's short SHA; write `source_ref` and `source_sha` to the hand-off and keep them through `gcp-tf-handoff` regeneration; refuse to run with no ref unless `GCP_TF_DEMO_REF=HEAD` is explicit. | P1-PRE | bats with stubbed git and gcloud: payload SHA equals the ref SHA; a dirty principal tree does not change it; `source_sha` survives a regenerated hand-off; missing ref fails with a named error | M | antigravity | — | — | — | — | — |
| P1-3 | implementation | In `demo-pipeline.sh`, for `ci` lanes add stages: `scripts/dual-cluster-up.sh`, `scripts/remote-tenant-lab.sh --load-kind-image`, `make test-kusari-e2e`, `KUSARI_LIVE=1 bats test/kusari-e2e-live.bats` (fails on any `# skip`), `scripts/slaws-acceptance.sh`, `make test-eap-offline`; each records its rc. Remove `test/tetragon-telemetry-stream.bats` from both `demo-pipeline.sh:820` and `vm-pipeline.sh:780` in one commit (announce to sensai-sltm on `/tmp/chat.jsonl`). | P1-PRE | bats with a stub runner: `ci` lanes run all six in order, `demo` lanes none; a failing or skipping stage fails the pipeline by name; `terraform-dual-lane-registration.bats` green; neither pipeline names a Tetragon suite | L | antigravity | — | — | — | — | — |
| P1-4 | implementation | Make every workflow under `.github/workflows/` on this branch manual-only: remove `pull_request`, `push` and `schedule` triggers, keep `workflow_dispatch` and `workflow_call`; update `test/eap-pr-workflow.bats` to assert the manual-only contract; record (do not fix) the pre-existing TFID digest failure for `vm-pipeline.sh` and `ci-lock.sh`. | P1-PRE | A bats test asserts no workflow on the branch has `pull_request`, `push` or `schedule`; `eap-pr-workflow.bats` green; YAML parses (`yq`); docs-lint clean | S | antigravity | — | — | — | — | — |
| P1-5 | implementation | Add `extraMounts` to `infra/kind/cluster-osramp.yaml` (and the hub cluster config used by `dual-cluster-up.sh`) binding the host dirs named by the existing `POSTGRES_DATA_DIR` (`.cache/postgres`), `ZOT_CACHE_DIR` (`.cache/zot`) and a new `LOCAL_PATH_DATA_DIR` (`.cache/local-path`) variables (`Makefile:66-67`) to `/var/local/signalloom-postgres-data` (uid 70, mode 0700), `/var/local-path-provisioner` and `/var/local/osramp-zot-cache`; `dual-cluster-up.sh` creates them before `kind create`; reconcile with `create-kind-cluster.sh` so one definition serves both; add a new script `kind-data-backup.sh` in `scripts/` with `backup <cluster> <dir>` and `restore <cluster> <dir>` subcommands using `docker cp` from the node. | P1-PRE | bats: the rendered kind config carries all three mounts with existing host dirs and correct ownership; backup then restore with a stubbed `docker` round-trips a fixture tree byte-for-byte; `create-kind-cluster.sh` and `dual-cluster-up.sh` produce the same mount set | M | antigravity | — | — | — | — | — |
| P1-6 | implementation | Make `GET /api/v1/observations` deterministic and pageable without changing the JSON array body: sort `(timestamp DESC, id DESC)` in the `GET /api/v1/observations` handler, before `scopeObservations` applies `limit`; leave `QueryRange` order untouched, because replay (`api/policy_routes.go`, `e2e/harness.go`) depends on it; accept `cursor=<opaque>` (encodes the last `(timestamp, id)`); return `X-Next-Cursor` and `Link: <…>; rel="next"` when more rows exist and `X-Result-Truncated: false` when they do not; reject a malformed cursor with 400 and a message naming the fix; move `signal_fusion.py` and `test/kusari-e2e-live.bats` (`observations_store`) to cursor paging (`policy-engine` only posts to `/evaluate` and is not a reader); document ordering and paging in the signal-ingest API docs with a worked `curl` example; re-pin the image (`scripts/signal-ingest-image-tag.sh`). | P1-PRE | Go: 50 identical requests return byte-identical bodies on both stores; cursor paging over a 1,000-row fixture with duplicate timestamps visits each id exactly once; a mutation removing the sort fails; malformed cursor is 400; `TestReconciledManifestRunsTheImageBuiltFromThisSource` green; pytest for `signal_fusion` paging; docs-lint clean | L | antigravity | — | — | — | — | — |
| P1-GOV | governor | Merge P1-1..P1-6 in order into `integration/eapci-v0.1.0`; run the four §5 offline commands twice with identical totals; append errata. | P1-1, P1-2, P1-3, P1-4, P1-5, P1-6 | Two identical acceptance runs; errata complete | M | antigravity | — | — | — | — | — |
| P2-PRE | preflight | Gate: `gcloud --version` loads; impersonation check (`gcp_tf_require_impersonation`); `tailscale status` up; state bucket readable; `TF_STATE_BUCKET` and `GCP_TF_VAR_FILE` set; the operator's live tfvars has the `demo-2` pilot profile. Stop and report on any failure. | P1-GOV | Six checks recorded in errata | S | antigravity | — | — | — | — | — |
| P2-1 | implementation | `make gcp-tf-up ENV=ci-1`, `make gcp-tf-demo-up ENV=ci-1 GCP_TF_DEMO_REF=integration/eapci-v0.1.0`, `make doctor-node ENV=ci-1`, `make gcp-tf-test-both ENV=ci-1`; collect the P1-3 stage results. | P2-PRE | Hand-off `source_sha` equals the integration tip short SHA; all six EAP stages rc 0 with zero skips; tailnet receipt present | M | antigravity | — | — | — | — | — |
| P2-2 | implementation | The same four targets for `ENV=demo-2` (destroying its current deployment, approved by AJM), deployed as the Kusari pilot at `sl-eap-4b53ab6b.taild4da3.ts.net`; run the onboarding smoke (`docs/EAP/onboarding.md` §1-§5); run the stun chain: `POST /act/read-passwd` → warden in-sentinel eBPF observation → stun label → authorised resume. | P2-1 | Hand-off SHA matches; the endpoint resolves on the tailnet; a sentinel observation for `/etc/passwd` from `agent-kusari`; `signalloom.io/stunned=true` then cleared by resume; no Tetragon CRD; smoke transcript | M | antigravity | — | — | — | — | — |
| P2-3 | implementation | The same four targets for `ENV=demo-1` at the integration tip; then `make gcp-tf-surfaces-report LANES='ci-1 demo-2 demo-1' COMMIT=<short tip SHA recorded at P2-PRE>`. | P2-2 | Zero STALE and zero MISSING across the three lanes; hand-offs dated today; `ci-2` untouched | M | antigravity | — | — | — | — | — |
| P2-4 | implementation | Migrate local `kind-osramp` (and `kind-signalloom-hub`) to the P1-5 mounts: declare a window on `/tmp/chat.jsonl` and wait for no objection; record Postgres row counts, the FrostDB observation count and kagent DB rows; the new `kind-data-backup.sh backup`; rebuild with `scripts/cluster-scratch-standup.sh`; restore; re-record counts; then `kind delete cluster` and rebuild once more without restore and re-record. | P2-PRE | Counts equal across all three readings; `docker inspect` shows host binds for the three paths; Kusari live tier 7/7 using cursor paging; two identical observations requests return identical bodies; no data under the node's anonymous `/var` volume | M | antigravity | — | — | — | — | — |
| P2-GOV | governor | Reconcile P2 evidence; confirm `ci-2` untouched; close errata; request AJM final approval. | P2-1, P2-2, P2-3, P2-4 | Errata complete; surfaces-report attached | S | antigravity | — | — | — | — | — |

### Spec: Errata

_Cards append `#### Errata — EAPCI-<ID>` blocks here in delivery order. Nothing has run._

#### Amendment — 2026-10-06 12:42 +0100 (before any card ran)

- AJM decision: the Kusari pilot repurposes lane `demo-2`. No fifth lane, no lane-kind or regex change, no quota request.
- AJM decision: no GitHub Actions jobs for this branch. Deploys are local only.
- Adopted from an unannounced external edit: the pilot endpoint is the salted EAP host `sl-eap-4b53ab6b`. That edit's claim that gcloud works was false inside the agent sandbox at 12:45. Its uncommitted `Makefile` and `test/terraform-make-contract.bats` changes admitting `pilot-kusari` in the main checkout are not part of this mission.
- Council corrections:
  - `dual-cluster-up.sh` creates the second cluster.
  - `RUN_COMMIT` and hand-off regeneration must carry the pinned SHA.
  - `surfaces-report` needs `LANES` and a short SHA.
  - Tailnet receipts need `gcp-tf-test-both`.
  - `ACT_ENABLED` needed a code gate (withdrawn at the second amendment).
  - The `kubectl` check needs `-n fe-signalloom-agents`.
  - The live tier must fail on a skip.
  - The TFID digest test is already red at `c7b09517`.

#### Amendment 2 — 2026-10-06 13:04 +0100 (before any card ran)

- AJM decision: `/act` stays enabled on every lane, including the `demo-2` pilot, so the stun demo runs there. This supersedes playbook K8 and withdraws the `ACT_ENABLED` flag and gate.
- AJM decision: deterministic observations responses. Added P1-6 (stable order, cursor paging, clear truncation signal, consumers and docs).
- AJM decision: kind data persistence is paramount. Added P1-5 (host `extraMounts` and backup and restore) and P2-4 (migrate the local clusters and prove data survives a rebuild).
- Integrated from *In-Sentinel eBPF Migration and Tetragon Deprecation (2026-Q4)*:
  - The stun chain is detected by warden in-sentinel eBPF.
  - Lanes carry no Tetragon CRD.
  - P1-3 removes the Tetragon suite from both pipeline lists.
  - The rest of that proposal's scope stays with its own mission.

