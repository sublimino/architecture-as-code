# SLAC Phase 3 Governor Certification Evidence

**Mission:** Signal Loom in-cluster agent discovery and auto-claim  
**Card:** `SLAC-P3-GOV`  
**Verdict:** PASS — 36/36 ISA criteria verified  
**Certified:** 2026-09-09 (UTC)  
**Worktree:** `/home/andy/src/.worktrees/osramp-demo/slac-v0.1.0/governor`  
**Integration branch:** `integration/slac-v0.1.0`  
**Certification base:** `3c73509ea0c636f50854bded22b5662d39565484`

## Prompt-to-artifact checklist

| Requested outcome | Artifact or command | Evidence |
|---|---|---|
| Reconcile every prerequisite | Git ancestry check against ten distinct delivery commits | Every SHA in the prerequisite table is an ancestor of the certification base |
| Execute the canonical demo | `make demo-signalloom-autoclaim` | Exit 0; seven steps; live Kagent workload; result JSON status `pass` |
| Execute the complete BATS suite | `bats test/signalloom-autoclaim.bats` | Exit 0; 12/12 tests passed |
| Verify all 36 ISA criteria | `ISA.md` plus the criterion matrix below | Progress `36/36`; no unchecked criterion remains |
| Produce comprehensive evidence | This document | Prerequisites, code, tests, runtime, hashes, corrections, and qualifications recorded |
| Complete proposal errata | Obsidian proposal `### Spec: Errata` | Governor PASS block written through the Obsidian bridge after commit |
| Record cost accounting | `kanban-check.sh ... cost --json` | Mechanically sourced task and mission totals copied into proposal Result/Errata |
| Prove clean integration state | Git branch, ancestry, status, and diff checks | Recorded after the certification commit in proposal errata |
| Enter candidate-completion state | `MissionState.ts candidate --evidence-id ...` | Mission transition performed only after helper completion gates pass |
| Commit without pushing | Local Conventional Commit | Commit recorded in proposal; no `git push` executed |

## Prerequisite reconciliation

The board contained ten completed prerequisite cards plus one archived and
superseded P2-1 execution. The eleven card records resolve to ten distinct
delivery commits. `git merge-base --is-ancestor <sha> HEAD` exited zero for
each commit before Governor changes were committed.

| Card | Delivery commit | Reconciled |
|---|---|---|
| SLAC-P1-PRE | `2cd715bcaea288d6bf8fe8e17dc3445a6cb263e9` | ancestor |
| SLAC-P1-1 | `aac39706a3abf1a6732701b02831c1e16baa9799` | ancestor |
| SLAC-P1-2 | `aac39706a3abf1a6732701b02831c1e16baa9799` | ancestor |
| SLAC-P1-GOV | `a514fd5a6e8de1bbeab5b99d9f56e4681811ec4d` | ancestor |
| SLAC-P2-PRE | `a3f1e9968177bfb25b5a2a370e9d0612b9fade1c` | ancestor |
| SLAC-P2-1 (archived, superseded) | `dd6680c15473cb9c27cae1bc4e840e1ec42d23f9` | ancestor |
| SLAC-P2-2 | `ccf6e10541a6658136a33f455eb147223faae920` | ancestor |
| SLAC-P2-GOV | `d16d25ffae70abbb2269eee09ea513bf98e3af4e` | ancestor |
| SLAC-P3-PRE | `77c0b736595b811942f38a314d011deea772681a` | ancestor |
| SLAC-P3-1 | `0ffe976868ad98d685e6c87eabefe5af61fbb137` | ancestor |
| SLAC-P3-2 | `83e0dd4c982473fec8dad0dd52beee10730d0ec9` | ancestor |

Initial scoped board state was `done=10`, `in_progress=1`, `archived=1`;
`SLAC-P3-GOV` was the sole in-progress card. The helper reported a clean DAG
and zero doctor exceptions.

## Delivered corrections

- Canonical claim submission returns HTTP 201 and persists tenant-scoped,
  active registry state plus complete discovery and claim metadata.
- Claims emit exact immutable `agent.claimed` audit vocabulary, seed six
  baseline controls, persist 83% posture, origin verification, and lifecycle.
- Release persists suspension, hides inactive claims, and records actor-bound
  lifecycle evidence without deleting the Kubernetes workload.
- Tenant-scoped `(tenant_id, name)` uniqueness permits genuine same-name
  workloads in separate tenants while preventing duplicates within a tenant.
- Batch auto-claim consumes discovered workload facts only; it cannot fabricate
  a synthetic fallback agent when discovery is empty.
- The dashboard presents Auto-Claim actions, immediate resolved state, truthful
  Assessed posture, and Claim Agent actions in both dossier tabs.
- The demo supports automated, confirmed interactive, and ephemeral shadow-pod
  routes, and always cleans the shadow pod on exit.
- BATS uses consolidated database snapshots, avoiding transient exhaustion of
  the demo PostgreSQL instance while retaining direct persistence assertions.

Migration `035_agent_claim_contract.sql` was applied by the deployed backend:

```text
version=35
filename=035_agent_claim_contract.sql
applied_at=2026-09-09 02:49:15.12121+00
```

The regenerated contract and in-cluster bootstrap SQL copies pass the canonical
bootstrap drift guard.

## ISA verification matrix

| ISC | Verdict | Direct evidence |
|---:|:---:|---|
| 1 | PASS | `test_submit_claim_valid`; live BATS test 2 verifies HTTP 201 and granted response |
| 2 | PASS | `_execute_claim` active upsert; BATS snapshot verifies registry status/lifecycle |
| 3 | PASS | Claim config and `agent_origin_verifications`; BATS verifies SPIFFE, namespace, service account, metadata |
| 4 | PASS | Claim budget allocation and eBPF binding; BATS verifies requested/allocated budgets and sentinel flag |
| 5 | PASS | `claim_agent_by_id`; focused pytest verifies discovered-ID claim |
| 6 | PASS | `autoclaim_discovered`; pytest verifies discovered-only batch and empty-discovery no-op |
| 7 | PASS | Tenant-scoped active claims query; lifecycle pytest and BATS release assertions |
| 8 | PASS | Tenant-scoped claim detail query; lifecycle pytest verifies found/not-found paths |
| 9 | PASS | Release transaction persists suspension, transition, audit; BATS test 9 verifies active-list removal |
| 10 | PASS | Bearer dependencies on every claim endpoint; auth and tenant-isolation pytest coverage |
| 11 | PASS | Exact `agent.claimed` insertion plus append-only trigger; BATS verifies actor and action |
| 12 | PASS | Six baseline rows inserted transactionally; BATS verifies six evaluations and five passing |
| 13 | PASS | Registry `compliance_posture=83` asserted directly by BATS database snapshot |
| 14 | PASS | Kubernetes-workload origin insertion; BATS verifies `spiffe_svid` and subject |
| 15 | PASS | One discovered-to-active transition; BATS verifies exactly one transition after re-claim |
| 16 | PASS | Migration 035 enforces `(tenant_id, name)` uniqueness; Tenant B test proves collision-free isolation |
| 17 | PASS | BATS re-claims with changed tools/budget, verifies updated metadata and one registry row |
| 18 | PASS | Live post-claim inventory lookup resolves registry/discovery overlay |
| 19 | PASS | BATS and demo verify owner, team, active lifecycle, six controls, and 83% posture |
| 20 | PASS | BATS test 1 verifies unclaimed workload remains discovered and unlinked |
| 21 | PASS | Stored claim config preserves namespace, node, pod UID, framework, model, and service account |
| 22 | PASS | Existing proxy discovery remains live; focused proxy suites verify pod and Kagent CR projection |
| 23 | PASS | `AgentsPage` renders Auto-Claim only for discovered rows; component test passes |
| 24 | PASS | Component test verifies claim payload, disabled loading state, spinner, and toast feedback |
| 25 | PASS | Component test verifies local Resolved update without a second list request or reload |
| 26 | PASS | Overview and Access dossier tests verify Claim Agent actions for unclaimed records |
| 27 | PASS | Table and overview tests verify numeric posture plus Assessed badge |
| 28 | PASS | Identity test verifies claimed Kubernetes workload, SPIFFE method, issuer, subject, and VERIFIED badge |
| 29 | PASS | `bun run build` exits zero after TypeScript and Vite production compilation |
| 30 | PASS | Automated and piped-confirmation interactive routes both complete seven live steps |
| 31 | PASS | Root Make target invokes the canonical script; live target exits zero |
| 32 | PASS | Live target discovers Kagent Incident Responder unclaimed, claims it, and verifies governance |
| 33 | PASS | Live shadow route deploys, discovers, claims, verifies, and removes an ephemeral pod |
| 34 | PASS | Live BATS lifecycle suite passes 12/12, including release, tenancy, validation, and demo contract |
| 35 | PASS | Changed-metadata re-claim returns 201, keeps one row, and keeps one activation transition |
| 36 | PASS | Genuine Tenant B row cannot be read or claimed by Tenant A; both requests return 404 |

## Command and transcript evidence

All timestamps are UTC. Raw transcripts are retained in `/tmp/opencode` for
the lifetime of the execution host; SHA-256 values make copied transcripts
tamper-evident.

| Command | Window | Exit/result | Transcript SHA-256 |
|---|---|---|---|
| `make demo-signalloom-autoclaim` | 03:24:34–03:24:35 | 0; 7/7 steps | `ff75f45e98016b2d0316d6d875667df0bc1e92765dad9bddd2d236a5fe8208e1` |
| `bats test/signalloom-autoclaim.bats` | 03:23:14–03:23:16 | 0; 12/12 | `8a7b1e032aa8aa28d5b0eb7e770c2c0b348d7c7b3a25d79f590a08c5f38b4fb1` |
| `scripts/demo-agent-autoclaim.sh --shadow` | 03:05:04–03:05:38 | 0; shadow claimed and removed | `dbfe30658712b04d758cbd21b85535430d60e85aeba1d47432c594c2fcb2b8b8` |
| `printf y \| scripts/demo-agent-autoclaim.sh --interactive` | 03:06:07–03:06:08 | 0; confirmation path | `93e0e9834ca7f3f2c4e0a7b9baf020b9fdd9d529085a740245f3a122d729d190` |
| Focused claim/audit pytest | 03:18:33–03:18:37 | 0; 23 passed | `158e98a4afef6e01bf449377ec0b9f07de72aeb5aa82ac6699f4d4ee02e21970` |
| `bun run test --run && bun run build` | 03:22:13–03:22:41 | 0; 3,086 passed, 1 skipped; build passed | `5a9975892fe20d5b8560a55463d950469a561efc47d6601eb29c6a54c9eb652c` |
| Syntax, bootstrap drift, diff check | 03:22:57 | 0 | `cb34a2fb2cd796492859671910cea499fe6faab8bd0bc13632b082ecfa168276` |

The final demo result JSON has SHA-256
`3dee1dfffb4c0700cd0119f5a949d6ada0698c8171df1d195e1ee52b95803bce`
and records `status=pass`, `steps_completed=7`, six controls, 83% posture,
exact `agent.claimed`, principal actor attribution, and zero background
processes.

## Runtime deployment proof

- `fe-signalloom`: ready `1`, available `1`, updated `1`.
- `dashboard-signalloom`: ready `1`, available `1`, updated `1`.
- Backend source identity: `523dbc9abd6458be06837d1f8fbcfe97279f2af1c2fd7cf9e7dfa50461e2a791`.
- Dashboard source identity: `0ca04c57a35bcab949eadae6ce73bf1530795687a055e61eb4850a5d9ab0f52c`.
- The successful shadow selector returns zero pods after script exit.

## Corrections discovered during certification

1. The initial expanded BATS run exposed PostgreSQL `too many clients` after
   repeated short-lived Bun pools through `kubectl port-forward`. One
   consolidated snapshot per lifecycle stage reduced connection churn; the
   final suite passed 12/12.
2. The first shadow run was rejected because the ephemeral pod lacked the
   admission-required `signalloom.ai/framework` label. The pod now declares
   `framework=custom`.
3. The second shadow run exposed an invalid readiness selector because explicit
   labels suppress kubectl's implicit `run=` label. Readiness now uses the
   explicit `app.kubernetes.io/name` label; the route then passed and cleaned up.
4. The result JSON recorded six completed steps before the seventh display
   message. The writer now records seven on successful completion; the final
   JSON proves `steps_completed=7`.

## Qualifications and boundaries

- Headless Chromium could not start inside this sandbox (`chrome EACCES` and
  `/proc/self/uid_map EACCES`). No browser screenshot is claimed. UI behavior
  is supported by the complete 3,086-test Vitest run, focused interaction tests,
  a successful production build, and a ready rebuilt dashboard workload.
- A delegated read-only audit accidentally invoked `supervise --dry-run`, which
  incremented supervisor preview bookkeeping from six to seven. It performed no
  card, branch, repository, or lifecycle mutation.
- No OpenBao plugin, Kagent CRD/controller, Envoy ingress definition, upstream
  repository, or production environment was modified.
- No push was performed. Candidate completion remains distinct from final
  principal approval, as required by the mission-state contract.
