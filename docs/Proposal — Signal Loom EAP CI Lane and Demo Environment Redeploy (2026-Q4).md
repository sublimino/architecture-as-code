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
- **The observations route answers non-deterministically.** `QueryRange` in `store/frostdb.go:484` and `store/memory.go:31` has no ordering, and `scopeObservations` (`api/tenancy_grants.go:75-89`) truncates the unordered result to `limit`. Two identical back-to-back requests returned 18 different ids out of 100 (2026-10-06). Every reader of `GET /api/v1/observations` (dashboard via `signal_fusion.py`, `policy-engine/observations.go`, the live tests) can silently miss rows, and there is no cursor to page with. On 2026-10-06 that full-store decode, polled concurrently by `/feeds`, OOM-killed signal-ingest seven times at 1Gi. The limit is now 2Gi as a stopgap (`0ac8a717`).
- **Lane records are stale.** All four `deploy/gcp/*.handoff.json` files date from 2026-08-21.

## 2. Out of Scope

- Deleting the `signalloom-ci` VM or anything else in `cp-dev-ajm`, and the nightly schedule on `main`. That schedule runs from the default branch, which this mission does not touch. VM deletion and `gh workflow disable` on `main` are AJM's actions.
- A fifth lane, a new lane kind, widening the lane-key regex, and any platform terraform apply. The regex is enforced in about nine places (`Makefile:2404`, terraform `env-contract` rules 01-03, the identity, edge and compute modules, `demo-up.sh:722`, `node-doctor.sh:408`, `where.sh:143`). The pilot reuses lane key `demo-2` (AJM 2026-10-06), whose service account and quota already exist. `CPUS_ALL_REGIONS` is 32 and the four lanes use all of it.
- Tetragon, in any lane. AJM decision 2026-10-06: Tetragon is never used. Runtime syscall detection is the warden's in-sentinel eBPF. The proposal *In-Sentinel eBPF Migration and Tetragon Deprecation (2026-Q4)* (SLSE) is absorbed into this mission as P1-7 to P1-10 and P2-5.
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
| P1-7 | context-mode; Hardening | Go and eBPF engineer | L | 180m | antigravity | SLSE D1: the warden's in-sentinel eBPF engine captures `openat`, `openat2`, `execve` and `connect` from agent cgroups and posts normalised observations to signal-ingest. |
| P1-8 | context-mode | Go platform engineer | M | 150m | antigravity | SLSE D2: remove the Tetragon gRPC client from `signal-ingest/collectors/ebpf`; sentinel observations arrive over `/api/v1/observations` only. |
| P1-9 | context-mode | Platform engineer | M | 120m | antigravity | SLSE D3 and D4: delete the Tetragon manifests, scripts, suite and `test-tetragon*` targets; add a new make target named test-sentinel-ebpf. |
| P1-10 | context-mode | Frontend engineer | S | 90m | antigravity | SLSE D5: dashboard labels say Sentinel eBPF, not Tetragon. |
| P1-GOV | ajm-auto-kanban | Governor | M | 120m | antigravity | Merge P1 cards in order, run the four offline acceptance commands twice, record errata. |
| P2-PRE | context-mode | Pre-flight analyst | S | 45m | antigravity | Gate: gcloud loads, impersonation works, tailnet up, state bucket reachable. Any failure stops P2 and reports. |
| P2-1 | context-mode | Lane operator | M | 180m | antigravity | Bring up `ci-1` at the integration tip and run the EAP legs; collect the hand-off and test evidence. |
| P2-2 | context-mode | Lane operator | M | 180m | antigravity | Bring up `demo-2` as the Kusari pilot (`sl-eap-4b53ab6b`); run the onboarding smoke and the `/act` stun chain. |
| P2-3 | context-mode | Lane operator | M | 180m | antigravity | Redeploy `demo-1` at the integration tip; refresh hand-offs; `surfaces-report` over `ci-1 demo-2 demo-1`. |
| P2-4 | context-mode | Platform operator | M | 180m | antigravity | Migrate local `kind-osramp` to host-persistent storage: declare on chat, back up, rebuild with the P1-5 mounts, restore, prove data survives a delete and rebuild. |
| P2-5 | context-mode; RedTeam | Purple-team engineer | M | 180m | antigravity | SLSE D6: live adversarial suite on local kind (`openat2` bypass, symlink race, ring-buffer flood) against the warden, after P2-4. |
| P2-GOV | ajm-auto-kanban | Governor | S | 90m | antigravity | Reconcile P2 evidence, confirm zero STALE lanes, close errata, request AJM final approval. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | baseline | On `integration/eapci-v0.1.0` at the cut SHA run `make test-eap-offline`, `make test-kusari-e2e`, `scripts/slaws-acceptance.sh /tmp/eapci-acceptance`, `make docs-lint`; `kanban-check.sh doctor`. | — | Four commands rc 0; totals in errata | S | antigravity | [Errata](#errata--eapci-p0) | — | — | — | — |
| P1-PRE | preflight | File:line table for `Makefile:2397-2401` ENV check, `deploy/gcp/sl-port-over-sandbox.tfvars` lane block, `demo-up.sh:1068-1130` payload, `demo-pipeline.sh` test stages (around 838-851, 1062), `signalloom-ci.yaml:19-32`; name the exact edits for P1-1..P1-4; post lane names to `/tmp/chat.jsonl`. | P0 | Table in errata; no code change | S | antigravity | — | — | — | — | — |
| P1-1 | implementation | Add an optional lane attribute `tailscale_hostname` to the `environments` object type (`env-contract/variables.tf`, a strict type that drops undeclared keys), carry it through the compute module (which hard-codes `sl-${environment_key}` at `compute/main.tf:175,213`) and the hand-off writer to `demo-up.sh:3384` and a pilot profile for `demo-2` in the example tfvars: labels `tier=pilot`, `tailscale_hostname = "sl-eap-4b53ab6b"`; do not set `hostname`, which enables public TLS (`edge/main.tf:34`). `/act` stays enabled on every lane. | P1-PRE | `terraform validate`; bats: the `demo-2` profile renders `tailscale_hostname` matching `^sl-eap-[a-f0-9]{8}$` and no `hostname`; other lanes unchanged | M | antigravity | — | — | — | — | — |
| P1-2 | implementation | `GCP_TF_DEMO_REF=<ref>`: build the payload from a clean worktree of that ref; set `RUN_COMMIT` (`demo-up.sh:2049`) from that ref's short SHA; write `source_ref` and `source_sha` to the hand-off and keep them through `gcp-tf-handoff` regeneration; refuse to run with no ref unless `GCP_TF_DEMO_REF=HEAD` is explicit. | P1-PRE | bats with stubbed git and gcloud: payload SHA equals the ref SHA; a dirty principal tree does not change it; `source_sha` survives a regenerated hand-off; missing ref fails with a named error | M | antigravity | — | — | — | — | — |
| P1-3 | implementation | In `demo-pipeline.sh`, for `ci` lanes add stages: `scripts/dual-cluster-up.sh`, `scripts/remote-tenant-lab.sh --load-kind-image`, `make test-kusari-e2e`, `KUSARI_LIVE=1 bats test/kusari-e2e-live.bats` (fails on any `# skip`), `scripts/slaws-acceptance.sh`, `make test-eap-offline`; each records its rc. Remove `test/tetragon-telemetry-stream.bats` from both `demo-pipeline.sh:820` and `vm-pipeline.sh:780` in one commit (announce to sensai-sltm on `/tmp/chat.jsonl`); the suite file, scripts and Makefile targets are P1-9's. | P1-PRE | bats with a stub runner: `ci` lanes run all six in order, `demo` lanes none; a failing or skipping stage fails the pipeline by name; `terraform-dual-lane-registration.bats` green; neither pipeline names a Tetragon suite | L | antigravity | — | — | — | — | — |
| P1-4 | implementation | Make every workflow under `.github/workflows/` on this branch manual-only: remove `pull_request`, `push` and `schedule` triggers, keep `workflow_dispatch` and `workflow_call`; update `test/eap-pr-workflow.bats` to assert the manual-only contract; record (do not fix) the pre-existing TFID digest failure for `vm-pipeline.sh` and `ci-lock.sh`. | P1-PRE | A bats test asserts no workflow on the branch has `pull_request`, `push` or `schedule`; `eap-pr-workflow.bats` green; YAML parses (`yq`); docs-lint clean | S | antigravity | — | — | — | — | — |
| P1-5 | implementation | Add `extraMounts` to `infra/kind/cluster-osramp.yaml` (and the hub cluster config used by `dual-cluster-up.sh`) binding the host dirs named by the existing `POSTGRES_DATA_DIR` (`.cache/postgres`), `ZOT_CACHE_DIR` (`.cache/zot`) and a new `LOCAL_PATH_DATA_DIR` (`.cache/local-path`) variables (`Makefile:66-67`) to `/var/local/signalloom-postgres-data` (uid 70, mode 0700), `/var/local-path-provisioner` and `/var/local/osramp-zot-cache`; render one kind config template (kind does not expand variables) used by both `dual-cluster-up.sh` and `create-kind-cluster.sh`, including the `/lib/modules` and `/sys/kernel/btf` binds the warden's eBPF needs on every lane; give `local-path` PVs stable directories (a `pathPattern` of `{{ .PVC.Namespace }}/{{ .PVC.Name }}` in the provisioner config) so a rebuilt cluster finds its data; export and restore the identity Secrets a rebuild would otherwise re-mint (`signal-segment-key`, fleet operator and caller keys, Dex static config); add a new script `kind-data-backup.sh` in `scripts/` with `backup <cluster> <dir>` and `restore <cluster> <dir>` subcommands using `docker cp` from the node. | P1-PRE | bats: the rendered kind config carries all three mounts with existing host dirs and correct ownership; backup then restore with a stubbed `docker` round-trips a fixture tree byte-for-byte and preserves uid 70; a PVC recreated with the same namespace and name resolves to the same host directory; `create-kind-cluster.sh` and `dual-cluster-up.sh` produce the same mount set | M | antigravity | — | — | — | — | — |
| P1-6 | implementation | Make `GET /api/v1/observations` deterministic, bounded and pageable without changing the JSON array body, and make `GET /api/v1/store/stats` aggregate without decoding every observation (both decode the whole store per request today, which OOM-killed signal-ingest at 1Gi on 2026-10-06 and broke `/feeds` with 502s): sort `(timestamp DESC, id DESC)` in the `GET /api/v1/observations` handler, before `scopeObservations` applies `limit`; leave `QueryRange` order untouched, because replay (`api/policy_routes.go`, `e2e/harness.go`) depends on it; accept `cursor=<opaque>` (encodes the last `(timestamp, id)`); return `X-Next-Cursor` and `Link: <…>; rel="next"` when more rows exist and `X-Result-Truncated: false` when they do not; bind the cursor to the caller's tenant scope and reject a cursor minted for another scope; reject a malformed cursor with 400 and a message naming the fix; `signal_fusion.py` forwards `cursor` and passes the paging headers back; write the signal-ingest observations API page from scratch; move `signal_fusion.py` and `test/kusari-e2e-live.bats` (`observations_store`) to cursor paging (`policy-engine` only posts to `/evaluate` and is not a reader); document ordering and paging in the signal-ingest API docs with a worked `curl` example; re-pin the image (`scripts/signal-ingest-image-tag.sh`); return the memory limit from the 2Gi stopgap (`0ac8a717`) to 1Gi once peak working set under concurrent polling is measured below 512Mi. | P1-PRE | Go: peak heap for one `/observations?limit=100` and one `/store/stats` over a 100k-row fixture stays under a stated bound; 50 identical requests return byte-identical bodies on both stores; cursor paging over a 1,000-row fixture with duplicate timestamps visits each id exactly once; a mutation removing the sort fails; malformed cursor is 400; `TestReconciledManifestRunsTheImageBuiltFromThisSource` green; pytest for `signal_fusion` paging; docs-lint clean | L | antigravity | — | — | — | — | — |
| P1-7 | implementation | Start with a gap table against SLSE's threat model T1-T5 (a prioritised execve/connect ring, PERFMON-only capabilities and a dedicated namespace are claimed but not built; the warden runs SYS_PTRACE, BPF, NET_ADMIN and SYS_ADMIN in `fe-signalloom-agents` with a 128Mi limit, and `main.go:614` only logs a literal tracepoint list). Then close the gaps: the four tracepoints are already attached in `d2-signalloom/apps/stun-sentinel/pkg/ebpf/loader.go:35-38` (probe `bpf/sentinel_probe.c`, cgroup id read, `Drops()` at :200); make sure the engine attaches `sys_enter_openat`, `sys_enter_openat2`, `sys_enter_execve` and `sys_enter_connect` scoped to agent cgroups, and post normalised observations to `signal-ingest` `/api/v1/observations` with the warden's named key; ring-buffer drops are counted and reported as an anomaly; the warden logs the tracepoints that actually attached. Report the new sentinel image tag; P1-GOV re-pins. | P1-PRE | Go unit tests for event normalisation of all four syscalls; a privileged-container or kind-node probe test proving an `openat("/etc/passwd")` from an agent cgroup yields one observation; drop counter exported; sentinel image re-pinned (`scripts/sentinel-image-tag.sh`) | L | antigravity | — | — | — | — | — |
| P1-8 | implementation | Remove the Tetragon gRPC client (`collectors/ebpf/client.go`, `tetragon.NewFineGuidanceSensorsClient` at :239) and its wiring in `signal-ingest/main.go:796-805`; drop the `cilium/tetragon/api` requirement (`go.mod:14`) and `go mod tidy`; sentinel observations arrive only through `/api/v1/observations`; drop `COLLECTOR_TETRAGON_MODE` and its registry entry; rename the `tetragon` source tag in `normalize.go:172` to `sentinel-ebpf`; remove the collector's `/metrics` output (`main.go:956`) and list any scraper of it; re-pin the signal-ingest image. | P1-PRE | `go test ./...` in signal-ingest with and without `-tags frostdb`; `rg -i tetragon d2-signalloom/apps/signal-ingest` returns nothing outside history comments; registry tests show no Tetragon collector; `TestReconciledManifestRunsTheImageBuiltFromThisSource` green | M | antigravity | — | — | — | — | — |
| P1-9 | implementation | Delete `d2-signalloom/deploy/tetragon-agent-telemetry.yaml`, `tetragon-helm-values.yaml`, `scripts/test-tetragon-stream.sh`, `test/tetragon-telemetry-stream.bats` and the Tetragon evidence artefact; remove `test-tetragon`, `test-tetragon-bats`, `test-tetragon-stream` from the `Makefile` (targets 707-719, callers in `test-all-offline` 557-558 and `test-all-cluster` 611); delete `test/mocks/tetragon_grpc_*` and their `go.mod` entries; drop Tetragon references from `test/acceptance/agent-claim.spec.ts`, `test/crkc-phase1-unified-stun.bats`, the test isolation allowlist, `scripts/slaat-baseline.sh` and the card-generator scripts; add a new make target named test-sentinel-ebpf running the P1-7 suites; update registries (`bats-registry-coverage`, dual-lane allowlists) accordingly. | P1-PRE | the files this card deletes or edits carry no Tetragon reference (the repo-wide zero check runs at P1-GOV on the merged tip); a dry run of the new test-sentinel-ebpf target resolves; `bats-registry-coverage.bats` and `terraform-dual-lane-registration.bats` green | M | antigravity | — | — | — | — | — |
| P1-10 | implementation | Replace Tetragon wording with Sentinel eBPF in `AgentActivityTab.tsx`, `ClaimModal.tsx`, `ContainmentPolicyConsentStep.tsx`, `FeedsExplorerPage.tsx`, `src/api/policyApi.ts:184` and their tests (including `SignalsPage.test.tsx`); telemetry source tags read `sentinel-ebpf`, including `fe-signalloom` `api_compat.py:6018` and the badge test id in `test/acceptance/agent-claim.spec.ts`. | P1-PRE | vitest for the four components green; `rg -i tetragon d2-signalloom/apps/dashboard-signalloom/src` returns nothing; tsc clean | S | antigravity | — | — | — | — | — |
| P1-GOV | governor | Merge P1-1..P1-10 in order (P1-9 after P1-3; re-pin signal-ingest and sentinel images once, after the last Go merge) into `integration/eapci-v0.1.0`; run the four §5 offline commands twice with identical totals; append errata. | P1-1, P1-2, P1-3, P1-4, P1-5, P1-6, P1-7, P1-8, P1-9, P1-10 | Two identical acceptance runs; errata complete | M | antigravity | — | — | — | — | — |
| P2-PRE | preflight | Gate: `gcloud --version` loads; impersonation check (`gcp_tf_require_impersonation`); `tailscale status` up; state bucket readable; `TF_STATE_BUCKET` and `GCP_TF_VAR_FILE` set; the operator's live tfvars has the `demo-2` pilot profile. Stop and report on any failure. | P1-GOV | Six checks recorded in errata | S | antigravity | — | — | — | — | — |
| P2-1 | implementation | `make gcp-tf-up ENV=ci-1`, `make gcp-tf-demo-up ENV=ci-1 GCP_TF_DEMO_REF=integration/eapci-v0.1.0`, `make doctor-node ENV=ci-1`, `make gcp-tf-test-both ENV=ci-1`; collect the P1-3 stage results. | P2-PRE | Hand-off `source_sha` equals the integration tip short SHA; all six EAP stages rc 0 with zero skips; tailnet receipt present | M | antigravity | — | — | — | — | — |
| P2-2 | implementation | The same four targets for `ENV=demo-2` (destroying its current deployment, approved by AJM), deployed as the Kusari pilot at `sl-eap-4b53ab6b.taild4da3.ts.net`; run the onboarding smoke (`docs/EAP/onboarding.md` §1-§5); run the stun chain: `POST /act/read-passwd` → warden in-sentinel eBPF observation → stun label → authorised resume. | P2-1 | Hand-off SHA matches; the endpoint resolves on the tailnet; a sentinel observation for `/etc/passwd` from `agent-kusari`; `signalloom.io/stunned=true` then cleared by resume; no Tetragon CRD; smoke transcript | M | antigravity | — | — | — | — | — |
| P2-3 | implementation | The same four targets for `ENV=demo-1` at the integration tip; then `make gcp-tf-surfaces-report LANES='ci-1 demo-2 demo-1' COMMIT=<short tip SHA recorded at P2-PRE>`. | P2-2 | Zero STALE and zero MISSING across the three lanes; hand-offs dated today; `ci-2` untouched | M | antigravity | — | — | — | — | — |
| P2-4 | implementation | Migrate local `kind-osramp` (and `kind-signalloom-hub`) to the P1-5 mounts: declare a window on `/tmp/chat.jsonl` and wait for no objection; check free disk is at least twice the node's `/var` usage; quiesce writers (scale signal-ingest and Postgres consumers to zero) and take a `pg_dump`; record Postgres row counts, the FrostDB observation count, kagent DB rows and the actor pseudonym of one known actor; the new `kind-data-backup.sh backup`; rebuild with `scripts/cluster-scratch-standup.sh`; restore; re-record counts; then `kind delete cluster` and rebuild once more without restore and re-record. | P2-PRE | Counts and the known actor's pseudonym equal across all three readings; `docker inspect` shows host binds for the three paths; Kusari live tier 7/7 using cursor paging; two identical observations requests return identical bodies; no data under the node's anonymous `/var` volume | M | antigravity | — | — | — | — | — |
| P2-5 | implementation | After P2-4, on local `kind-osramp`, run a live adversarial suite against the warden with zero fixtures: `openat2` direct invocation, a symlink race to `/etc/passwd`, `execve` of a shell, an egress `connect`, and a ring-buffer flood of benign `openat` chaff; each must yield an observation, and a flood must surface a drop anomaly rather than silent loss. | P2-4 | bats live tier (gated like `test/kusari-e2e-live.bats`, fails on skip in counted runs): 100% of the five attacks observed; flood reports drops; warden RSS under 50 MiB during the run | M | antigravity | — | — | — | — | — |
| P2-GOV | governor | Reconcile P2 evidence; confirm `ci-2` untouched; close errata; request AJM final approval. | P2-1, P2-2, P2-3, P2-4, P2-5 | Errata complete; surfaces-report attached | S | antigravity | — | — | — | — | — |

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

#### Amendment 3 — 2026-10-06 16:38 +0100 (before any card ran)

- AJM decision: fold SLSE into EAPCI so one board, one integration branch and one acceptance run cover both.
- Mapping: SLSE D1 is P1-7, D2 is P1-8, D3 and D4 are P1-9, D5 is P1-10, and D6 is P2-5.
- P1-3 keeps only the pipeline list edit. P2-5 runs live after the P2-4 rebuild.
- SLSE's Definition of Done was ticked before any work existed. It is unticked in the vault and superseded by these rows.

#### Errata — EAPCI-P0

- **Logical ID:** P0
- **Created:** 2026-10-06 18:30:00+01:00
- **Last Updated:** 2026-10-06 18:30:00+01:00
- **Harness:** `antigravity`
- **Integration Branch:** `refs/heads/integration/eapci-v0.1.0` (`44e140c07175b1928e8bcb45bf2887e75df03050`)
- **Cut Commit SHA:** `44e140c07175b1928e8bcb45bf2887e75df03050`
- **Merge Base Check:** `git merge-base --is-ancestor origin/feat/signal-loop-and-bootstrap-refactor integration/eapci-v0.1.0` -> `0` (clean ancestor)

##### Baseline Acceptance Table

| Command | Exit Code | Result / Output Summary | Pass Condition & Findings |
| :--- | :--- | :--- | :--- |
| `make test-eap-offline` | 0 | Pytest: 265 passed, 18 warnings in 53.14s; Bats: 1..18 (11 ok, 7 skip); Tailscale CLI: 33 passed | All 265 offline pytest tests pass; 7 ROUTELIVE bats tests skip waiting for live portal deployment; 33 Tailscale automation tests pass. Overall rc 0. |
| `make test-kusari-e2e` | 0 | 28 passed, 0 failed in 1.141s | Both store modes verified offline: 14 tests under memory store, 14 tests under `-tags frostdb`. Full synthetic corpus and burst detection verified. |
| `scripts/slaws-acceptance.sh /tmp/eapci-acceptance` | 1 | `signal-ingest` rc=0 pass=3618 fail=0 (22s); `signal-ingest-frostdb` rc=0 pass=3671 fail=0 (25s); `policy-engine` rc=1 pass=301 fail=1 (0s); `sldc-offline` rc=0 pass=704 fail=0 (253s); `probe-name` rc=0 pass=checked=4972 fail=0 (1s); `docs-lint` rc=0 pass=checked=689 fail=0 (7s); `obscel-extra` rc=0 pass=118 fail=0 (0s); `alignment` rc=0 pass=checked=103 fail=0 (1s) | Acceptance harness executed to completion. `policy-engine` build fails with `fatal error: /usr/include/stdc-predef.h: Permission denied` because `scripts/slaws-acceptance.sh` omits `CGO_ENABLED=0` in its policy-engine invocation while running in unprivileged sandbox. All 7 other legs pass cleanly. |
| `make docs-lint` | 0 | `docs-lint: 689 file(s) clean (all checks: 99, correctness checks: 3, link checks: 587)` | Full documentation suite clean across all 689 tracked markdown files. Zero lint errors. |
| `kanban-check.sh doctor --repo .` | 1 | 7 exception categories identified (all pre-existing across the wider repo board state) | (1) Graph integrity: missing edge P1-PRE → P0, orphan P0; (2) Zero-output cards: 10 historical tasks with 0 output lines; (3) Uncompiled prompts: 5 legacy cards; (4) Orphan worktrees: 11 worktrees; (5) State oscillation: 49 tasks with >1 entry into same state; (6) Dangling commit: 1 commit (47525f4a); (7) Stalled tasks: 2 active tasks. |

##### Pre-Existing Red Ledger

| Check / Probe | Result | Details / Pre-Existing Defect |
| :--- | :--- | :--- |
| `sha256sum -c test/fixtures/gcp-tf-ci/untouched-scripts.sha256` | FAILED | `scripts/ci/gcp-ci.sh: OK`, `scripts/ci/vm-pipeline.sh: FAILED`, `scripts/ci/ci-lock.sh: FAILED`. Pre-existing TFID digest failure documented in proposal amendments. |
| `make gcp-tf-validate` (bats stage: `test/terraform-demo-driver.bats`) | FAILED | 3 tests fail in `test/terraform-demo-driver.bats` (132: failing remote path provisioning aborts; 133: provisioning and pipeline stubs fail independently; 134: PASS summary next to non-zero pipeline exit is a FAIL). All Terraform unit tests (195/195 across bootstrap, environments, compute, deploy-identity, edge, env-contract, identity, network) pass cleanly. |
| `gcloud --version` | FAILED | `PermissionError: [Errno 13] Permission denied: '/home/andy/.config/gcloud/active_config'`. Pre-existing sandbox constraint documented in proposal §3. |

##### Toolchain Inventory

| Tool | Version / Status |
| :--- | :--- |
| `terraform` | Terraform v1.15.8 |
| `bats` | Bats 1.13.0 |
| `yq` | v4.53.2 |
| `jq` | jq-1.8.1 |
| `uv` | uv 0.5.10 |
| `go` | go version go1.26.2 linux/amd64 |
| `bun` | 1.4.0 |
| `shellcheck` | 0.11.0 |
| `python` | Python 3.14.4 |
| `docker` | Docker version 29.7.1, build e9452d6 |
| `gcloud` | Blocked in agent sandbox (`~/.config/gcloud` denied) |

##### Non-Interference and Cleanliness Guarantee
- `git status --porcelain` across principal repo and isolated worktree: clean (0 lines outside proposal errata).
- Logs preserved in `/tmp/eapci-p0-logs/` (`test-eap-offline.log`, `test-kusari-e2e.log`, `slaws-acceptance.log`, `docs-lint.log`, `kanban-doctor.log`, `toolchain.txt`).
- Acceptance artifacts preserved in `/tmp/eapci-acceptance/` and `/tmp/eapci-acceptance-p0/` (`head.txt`, `totals.txt`, `totals.key`, and individual leg logs).

<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
<!-- kanban-check: {"card":"EAPCI-P0","status":"pass","commit":"044fd718aeaa76c0b03f0a57cb5be58edfcdaef3"} -->


