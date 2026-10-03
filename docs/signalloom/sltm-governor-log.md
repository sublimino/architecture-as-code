# SLTM Governor Log

Coordination channel for every supervisor, governor or lead session working
the SLTM board (Proposal — Signal Loom Spireless Token-Based Agent Identity
Migration (2026-Q4)). Append; never rewrite. Read the tail before acting.
Mission identity: repository `/home/andy/src/cp/osramp-demo`, shortcode
`SLTM`, integration branch `refs/heads/integration/sltm-v0.1.0`.

---

## 1. Board bootstrap by the lead session (sensai, Claude Code)

- **Timestamp**: 2026-10-03T01:06:26+0100
- **Authority**: Andy, verbatim: "override the human review, I trust that we've done enough preparatory work ... write the cards, test them with subagents for each card/council, start the board ... start the cron/loop supervisor process here ... don't ask for human permission", and "use the governor log to communicate with any other supervisors that might be working on this too. be sure you create the cards with the harness that has space".
- **Board appraisal applied before card creation**:
  - P1-1 retargeted: the afm-platform backend is not in this repository, so the `afm:import` key check lives in a fe-signalloom gateway route plus an afm-platform NetworkPolicy.
  - P2-1/P2-3 split by side: the probe (P2-1) stamps the D10 chain headers; signal-ingest (P2-3) verifies them. This removes a shared-file collision in the probe's dispatch path.
  - Harness: every card on `antigravity` (subscription telemetry: Codex throttled, Claude 54% of its 5-hour window, Antigravity 1%).
- **Other supervisors**: no SLTM supervisor exists. The last osramp-demo supervisor tick was SLAAT on 2026-10-02 12:23 (mission complete). If you are another session reading this: the lead session owns the SLTM lease. Post here before touching an SLTM card.

---

## 2. Feature branch advanced, integration branch cut, council started, live deploy running

- **Timestamp**: 2026-10-03T01:13:53+0100
- `feat/signal-loop-and-bootstrap-refactor` fast-forwarded to `20cd0b7c`. That includes Andy's 01:00 draft (`bbcc4c43`), merged with the appraised proposal kept. The main checkout was clean before and after.
- `refs/heads/integration/sltm-v0.1.0` cut at `20cd0b7c`; Governor worktree `~/src/.worktrees/osramp-demo/sltm-v0.1.0/governor`.
- Card council (4 members: implementation, test-and-evidence, failure-modes, integration/editor) is generating the 16 card specifications. Cards are created only through `kanban-check.sh create`.
- Lead live deploy to `kind-osramp` in progress: caller keys, source-tagged signal-ingest and probe images, fe/dashboard/fleet/supercred images, fleet and signalloom artifacts, and `tenants` resumed. The reviewed `flux diff` shows no prune beyond the intended removal of `agent-swarm-flux-cluster-rbac`. **Do not run live suites on kind-osramp until entry 3 says the deploy is verified.**

---

## 3. Live deploy verified; Phase 1 probe key proven twice; decisions recorded before P1 starts

- **Timestamp**: 2026-10-03T01:40:57+0100
- **Deploy (kind-osramp)**: every Kustomization Ready, no failing pods. Three deploy defects were fixed on the way:
  - An orphaned `stun-sentinel-node-reader` ClusterRole/Binding that Flux could no longer prune; the dead objects were removed and a rollback snapshot kept.
  - A duplicated env name in fe-signalloom; now guarded by `test/rendered-env-unique.bats`.
  - `kustomize.toolkit.fluxcd.io/force: "true"`, which kustomize-controller ignores; now `Enabled`, guarded by `test/flux-annotation-values.bats`.
  - Separately, stale `:dev` and `:local` images were restarted: fake-integration-proxy, netassert-controller and policy-engine.
- **Probe**: `ebpf_probe_attached`, `ringbuf_drops 0`, `ringbuf_prefiltered` climbing, `dispatch_ok` rising, `dispatch_errors 0`, `ingest_token_missing 0`.
- **SLTM Phase 1 DoD**: `SLTM_LIVE=1 make test-sltm-probe-apikey` passed 17/17 at 01:35:39 and 17/17 at 01:35:58 (+0100), with 0 skips.
- **Containment e2e**: Steps 1, 3, 4 and 5 are green; the freeze persists past a resync.
  - Step 2 was red because discovery was a stale image; it has been restarted.
  - Step 6 is red. `/recover` is authorised, but the outcome is `unavailable`: fleet-manager's SPIRE client fails with "server preface EOF" and OpenBao returns 403. **kusari is left frozen until fixed (lead working on it).**
- **Decision P1-PRE-5 (lead, before P1-1 starts)**: the dashboard RBAC importer panel's browser `POST /afm/clusters/import` is **re-routed through the fe-signalloom gateway as a superadmin-only second caller**, not closed. Closing it would break a shipped feature. The gateway checks the user's Dex token and superadmin role, then forwards with the `afm-importer` key. P1-1 implements this instead of the default close.
- **Decision P3 (lead)**: accept P3-PRE's recommendation to keep the Go module directories and the observation `source` value `stun-sentinel`, allow-listed. The source value is part of every observation ID, so renaming it breaks evidence continuity.
