# SLAAT-P1-PRE — pre-attack baseline (2026-10-01)

Captured before any Phase 1 attack probing. Phase 1 probe cards and the Phase 3 replay measure their delta against this.

- **Base:** card base was `73499882`; the card commits were rebased onto integration ref `refs/heads/integration/slaat-whole-system-adversarial` = `47d124ee`, so integration fast-forwards. The suites ran at `73499882`, whose tree differs from `47d124ee` only in `d2-osramp-fleet/tenants/base/agent-swarm.yaml` and `d2-signalloom/Makefile` (sentinel overlay and image tag). Neither file is exercised by an offline slice.
- **Re-run:** `SLAAT_CACHE_ROOT=/tmp/x scripts/slaat-preflight.sh` (environment, JSON on stdout) and `SLAAT_BASELINE_OUT=/tmp/y SLAAT_CACHE_ROOT=/tmp/x scripts/slaat-baseline.sh` (suites).
- **Evidence:** `preflight-env.json` (status `pass`) and `baseline-summary.tsv` (per-slice rc, seconds and verdict line) in this directory.

## Environment

| Tool | Version |
| :--- | :--- |
| bats | 1.13.0 |
| go | 1.26.2 linux/amd64 |
| pytest (via `uv run --python 3.12`) | 9.1.1 |
| python3 (host) | 3.14.4 |
| uv | 0.5.10 |
| kubectl (client) | v1.36.0 |
| curl | 8.20.0 |
| jq | 1.8.1 |

Cluster `kind-osramp`: 1/1 node Ready (v1.36.1), `inf-signalloom/postgresql` 1/1 Running, `registry/zot` 1/1 Running, `make healthcheck` green.

**Cache overrides are mandatory, not hygiene.** Every card must export `GOCACHE`, `GOMODCACHE`, `GOPATH`, `UV_CACHE_DIR` under a writable temp root and `CGO_ENABLED=0`. Without `UV_CACHE_DIR`, `uv run` fails in the sandbox: `failed to open file ~/.cache/uv/sdists-v6/.git: Permission denied`. The preflight checks that `go env` reports the overrides; it does not just assume the export took effect.

## Baseline by slice

| Slice | Command | Result |
| :--- | :--- | :--- |
| Acceptance | `make test-eap-offline` | **red, rc 2**: pytest 4 failed / 246 passed / 1 xfailed; ROUTELIVE bats 1 not ok; tailscale env 33/33 |
| Acceptance | `make test-postgres-persistence` | 7/7 ok |
| Acceptance | `make test-zot-cache` | 3/3 ok |
| Acceptance | `make healthcheck` | green |
| Acceptance | `make test-all-offline` | **not measurable in a worktree**: stage 1 Go was clean (105 `ok` packages, 0 `FAIL`), then stage 2 `bun install` stopped with `EEXIST` (see below) |
| Ingress | `eap-ingress-reconcile.bats` + `api-route-liveness.bats` | 14/15 ok; not ok 11 ROUTELIVE |
| API | fe-signalloom full pytest | **19 failed / 2347 passed / 94 skipped / 1 xfailed** |
| API | `authz-suite-liveness.bats` | 3/3 ok |
| SPIFFE | `make -C d2-agent-trust test` | 8/8 OK |
| SPIFFE | `make test-bao-spire-proof-harness` | 7/7 ok |
| Containment | `stun-sentinel` go test | 12 pkgs ok, 0 FAIL |
| Containment | `signalloom-stun-sentinel` go test | 3 pkgs ok, 0 FAIL |
| Containment | `nono-containment-probe` go test | ok |
| Containment | olly-replica sentinel pytest | 45 passed |
| Containment | `make test-tetragon-bats` | 27/27 ok |

## Pre-existing reds (recorded, not fixed)

These were already failing before any attack ran. For P1-2 they are leads, not regressions.

- **Tenant-scope sweep gap** (`test_tenant_isolation.py::test_the_route_sweep_covers_every_authenticated_api_route`). Nothing checks tenant scoping on 9 authenticated routes: `GET /api/telemetry/agents`, `GET /api/telemetry/agents/{pod_name}`, `GET /api/v1/agents`, `GET /api/v1/telemetry/agents`, `GET /api/v1/telemetry/agents/{pod_name}`, `POST /api/rbac/clusters/{cluster_id}/jobs`, `POST /api/rbac/clusters/{cluster_id}/scan`, `POST /api/v1/agents/{agent_id}/transition`, `POST /api/v1/discovery/claim`.
- **Vacuous DB route** (`test_every_database_statement_is_bound_to_the_callers_tenant[GET /api/v1/discovery/workloads]`). The route issues no database statement, so its `DB_ROUTES` entry checks nothing.
- **Unaudited mutations** (`test_audit_provenance.py::test_every_mutating_route_makes_an_audit_decision`). 15 mutating routes, across compliance `calculate_posture`/`scan_compliance`, policies `evaluate`/`register_bundle`/`rollback`/`validate`, and rbac_correlation cluster jobs/scan, have no audit write and no `NOT_AUDIT_WORTHY` entry.
- **Non-durable audit** (`test_no_new_non_durable_audit_path_has_been_added`). `agents.py:transition_agent_state` (line 181) and `discovery.py:claim_discovered_workload` (line 264) write audit events to memory instead of the database.
- **ROUTELIVE** (`api-route-liveness.bats` test 11, line 422). The dashboard calls `/api/discovery/claim`, but the running fe-signalloom does not serve it.
- **Other fe-signalloom pytest reds** (19 in total, including the 4 EAP ones above):
  - `test_agent_discovery.py`: 5
  - `test_api_compat.py`: 5 (enriched or operational inventory, agents filter)
  - `test_dashboard_audit_vocabulary.py`: 2
  - `test_adversarial_lifecycle.py::TestStateMachineConsistency::test_all_transition_targets_are_valid_states`: 1
  - `test_audit_ingest.py::test_process_metadata`: 1 (`ImportError`)
  - `test_connectors.py::test_connector_toggle_syncs_with_discovery`: 1

## Environment hazards for later cards

1. **Shared `node_modules` symlinks.** These worktree directories are symlinks into the principal checkout `/home/andy/src/cp/osramp-demo`:
   - `d2-signalloom/apps/dashboard-signalloom/node_modules`
   - `d2-signalloom/apps/docs-signalloom/node_modules`
   - `d2-signalloom/design-system-demo/node_modules`
   - `test/acceptance/node_modules`

   `make test-dashboard-weave` (stage 2 of `test-all-offline`) runs `bun install --frozen-lockfile` through that symlink. Here it failed with `EEXIST` and wrote nothing: no file in the principal's `node_modules` is newer than the run. A successful install would rewrite another checkout's dependencies. `scripts/slaat-preflight.sh` now warns on every such link.
2. **Suite-induced residue.** The baseline run rewrote two tracked files: `d2-signalloom/apps/signal-ingest/correlation/redteam_cascade_ceiling.json` (its `generated_at` and `max_cycle_latency_us` fields) and `docs/signalloom/evidence/sler-p6-3-acceptance-runtime.jsonl` (+7 lines). Both were reverted. Run `git status` after any suite before committing.
3. **Unwritable `.pytest_cache`.** `d2-signalloom/apps/fe-signalloom/src/.pytest_cache` is not writable (`PytestCacheWarning`, Errno 13). This is harmless, but `--lf` reruns will not work.
4. **Stale `scripts/kanban-check.sh`.** It delegates to `~/.andy_sync/confExt/skills/ajm-cline-kanban/Tools/kanban-check.sh`, which no longer exists (rc 127); the skill is now `ajm-auto-kanban`. Call the upstream tool directly until the wrapper is fixed.
