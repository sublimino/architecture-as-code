# SLDC-P5-1 - Five-step automated containment verification

Deploy → Claim → Provoke → In-Sentinel Detect → Freeze, across `kind-osramp`
(workload plane) and `kind-signalloom-hub` (control plane).

| Artefact | Path |
| :--- | :--- |
| Suite | [`test/e2e-dual-cluster-containment.bats`](../../test/e2e-dual-cluster-containment.bats) |
| Runner | [`scripts/run-e2e-dual-cluster-containment.sh`](../../scripts/run-e2e-dual-cluster-containment.sh) |
| Falsifiability proof | [`test/e2e-mutation-proof.sh`](../../test/e2e-mutation-proof.sh) |
| Provocation endpoints | [`d2-signalloom/apps/kusari-agent/main.go`](../../d2-signalloom/apps/kusari-agent/main.go) |
| Unit tests | [`d2-signalloom/apps/kusari-agent/main_test.go`](../../d2-signalloom/apps/kusari-agent/main_test.go) |
| Claim path | [`scripts/demo-agent-autoclaim.sh`](../../scripts/demo-agent-autoclaim.sh) `--workload kusari-agent` |
| Standalone workload | [`deploy/kusari-agent-workload.yaml`](../../deploy/kusari-agent-workload.yaml) |
| Execution trace | [`ci-evidence/sample-e2e-run.log`](../../ci-evidence/sample-e2e-run.log) |

## Running it

```bash
# full five-step run against the live dual-cluster estate
scripts/run-e2e-dual-cluster-containment.sh --tap

# one step
bats test/e2e-dual-cluster-containment.bats -f "Step 5: Pod is frozen"

# three consecutive runs (the Phase 5 Governor merge gate)
scripts/run-e2e-dual-cluster-containment.sh --repeat 3 --tap

# falsifiability proof - no cluster required, ~90s
test/e2e-mutation-proof.sh
```

Evidence lands in `--evidence-dir` (default `~/kusari-e2e/<timestamp>`, mode
0750) as `preflight-manifest.json.txt`, `step1-flux-reconcile.txt`,
`step2-registry-claim.json`, `step3-provocation-act.log`,
`step4-ebpf-observation.json`, `step5-cgroup-freeze.txt`,
`step5-cadvisor-metrics.prom`, `audit-signature.sha256`, `bats-output.log`,
`run-summary.json`.

## The five steps

| Step | Asserts | Probe |
| :--- | :--- | :--- |
| 1 Deploy | Flux Kustomization `agent-kusari-agent` Ready=True with a revision; rollout complete; pod Running with a populated UID; `restartCount == 0`; `1/1` ready | CRD status + `wait_rollout` |
| 2 Claim | Exactly one `agent_registry` row for `kusari-agent`, bound to tenant `kusari`, never the retired typo `kurasi`. Its `model_name` equals the pod's `signalloom.ai/model` label. The hash derives to `4b53ab6b`. When no row exists, the step first claims the agent through the product as `kusari-operator` | claim through the API, then a read-only `SELECT` and `scripts/derive_tenant_hash.py` |
| 3 Provoke | `POST /act/read-passwd` → 200 `{"action":"read-passwd","ok":true}` with `held_ms >= 50`, a real `tid`, `lines > 0`, and no file content in the body; `POST /act/read-shadow` → `attempted: true` | API-server pod proxy |
| 4 Detect | The first `sys_enter_openat` observation against `/etc/passwd\|/etc/shadow`, in time order, from one second before the provocation. It is normalized with `actor_id`, `pod_name`, `cgroup_path` and `tenant_id == kusari`, inside the correlation window | `GET ?limit=50&after=<provocation - 1s>` on `signal-ingest:8082` through the API-server service proxy |
| 5 Freeze | this pod's own `cgroup.events` reports `frozen 1`; Deployment **and** Pod carry `kustomize.toolkit.fluxcd.io/reconcile: disabled`; `restartCount == 0`; two distinct cAdvisor samples give exactly `0.000` mCPU; the frozen pod no longer answers traffic | kernel read on the node + kubelet cAdvisor proxy |

## Design decisions worth knowing

**No `kubectl exec` as a probe.** `exec` tunnels through the API server. It
would keep answering after the network quarantine is applied, so it would mask
the failure Step 5 exists to catch. Step 2 has two exceptions. The `SELECT` is
read-only, because the host has no `psql` and the database is not exposed. The
claim runs `scripts/demo-agent-autoclaim.sh`, which calls the API from inside
the dashboard pod. That is the product's claim path, not a probe.

**Step 2 never writes the registry with SQL.** No worker claims a workload by
itself. So when there is no row, Step 2 claims `kusari-agent` through
`POST /api/v1/agents/claim`. It claims as `kusari-operator`, the one Dex subject
that `API_SUBJECT_TENANTS` maps to tenant `kusari`. The claim script reads the
model and harness from the pod's labels and refuses a pod with no model label.
A row from an earlier run is not claimed again. The same assertions apply to it.
The claim script also grades compliance and audit, which Step 2 does not assert.
Step 2 records the script's exit code in `step2-registry-claim.json`, and the
row decides the result.

**No bare `sleep`.** Every wait is a deadline-bounded poll from
`scripts/lib/wait.sh`, so a slow machine is slow rather than red. Polled
predicates are exported shell functions, not command strings. `_wait_retry`
runs its argument through `bash -c`. The SQL nested inside that string put its
own `'|'` literals where they ended the inner `sh -c '...'`. Quoting belongs in
code, where the shell parses it once.

**The cgroup is resolved by pod UID, never `find … | head -1`.** Appendix F.1
reads the first `kubepods` cgroup it finds on the node. That cgroup belongs to
an arbitrary workload. On a shared cluster with other frozen agents, the
assertion would pass on another pod's freeze state. The suite derives
`pod<UID>.slice` from the pod under test.

**Teardown thaws only the cgroup this suite froze.** The reason is the same. A
blanket loop that writes `0` to every `cgroup.freeze` under `/sys/fs/cgroup`
would silently thaw every deliberately frozen agent on `kind-osramp`. It would
destroy another card's state.

**Step 4 reads a bounded window and takes the first detection.** Without a lower
bound, the store answers with its oldest 50 observations. After 50 had
accumulated, the provoked observation was never returned. So the query carries
`after=` one second before the provocation. The first read freezes the pod, and
the `/etc/shadow` read runs only after a thaw. So the detection is the earliest
sensitive observation, compared as times and not as strings.

**The CPU flatline compares two genuinely distinct samples.** cAdvisor serves a
cached housekeeping sample. Two quick reads of the same counter return the same
value, whether the container is frozen or burning a full core. The suite waits
for cAdvisor's own timestamp field to advance. Then it requires the counter to
be unchanged.

**Every external dependency is injectable.** The variables are `SLDC_KUBECTL`,
`SLDC_DOCKER`, `WL_CONTEXT`, `HUB_CONTEXT`, `DB_CONTEXT`, `NODE`, `NS`,
`EVIDENCE_DIR`, `SLDC_OBS_WINDOW_MS`, `SLDC_CLAIM_CMD`, `SLDC_CLAIM_USER` and
`SLDC_CLAIM_PASSWORD`. They let the mutation proof drive the real suite against
a fake cluster. `DB_CONTEXT` defaults to `WL_CONTEXT`, because the registry
database runs on `kind-osramp` in `inf-signalloom`.

## Falsifiability (Shared Pattern 6)

`test/e2e-mutation-proof.sh` runs the real suite against a hermetic fake
kubectl and docker pair. It runs once with baseline fixtures, where all five
steps pass. Then it runs once per mutation. Each mutation breaks exactly one
behaviour and must turn exactly the step that guards it red. The output is
TAP-13, and no cluster is needed. The baseline starts with no registry row. So a
green baseline proves that Step 2 creates the row through its claim command.

The mutations:

`step1_not_ready`, `step1_dirty_restart`, `step2_no_row`, `step2_wrong_tenant`,
`step2_legacy_typo`, `step2_no_model`, `step2_fabricated_model`,
`step2_split_claim`, `step2_claim_refused`, `step3_act_failed`,
`step3_descriptor_not_held`, `step3_shadow_not_attempted`,
`step4_probe_removed`, `step4_not_sensitive`, `step4_stale_timestamp`,
`step4_wrong_tenant`, `step4_legacy_typo`, `step5_freeze_disabled`,
`step5_restart_h1_breach`, `step5_no_flux_suppression`,
`step5_no_pod_suppression`, `step5_cpu_still_burning`, `step5_still_serving`.

A proven-falsifiable suite makes a red live run a finding about the estate, not
a suspicion about the suite.

## Provocation endpoints

`kusari-agent` gained three `POST`-only routes. Each answers a JSON envelope
whose first two fields are always `action` and `ok`.

| Route | Behaviour |
| :--- | :--- |
| `POST /act/read-passwd` | `open(2)` `/etc/passwd` **from the request's own OS thread** (`runtime.LockOSThread`), read it, hold the descriptor `ACT_HOLD` (default 100ms), report `bytes`/`lines`/`held_ms`/`pid`/`tid`. Never returns file content. |
| `POST /act/read-shadow` | The same against `/etc/shadow`. Reports `attempted: true` even when the file is absent - on a distroless image it is, and the `sys_enter_openat` is the signal, not the bytes. |
| `POST /act/cpu-burn` | Busy-loop `?threads=N` (default `GOMAXPROCS`, max 64) for `?duration=D` (default 5s, clamped to `ACT_BURN_MAX`, default 60s), each goroutine locked to its own OS thread. Answers only once the burn is over. |

The thread locking and the hold window exist because of a known failure mode.
A syscall from a helper thread that exits before the probe correlates it is
invisible to the sentinel.

`GET` on any `/act/*` route is `405` with `Allow: POST`. An unknown action is
`404`. A bad `duration` or `threads` is `400` with `ok: false`.

## Live status (2026-10-02)

Steps 1, 3 and 4 pass live. Step 4 first passed on 2026-10-01 with a detection
delta of 31 ms. It passed again at 27 ms after the query was bounded with
`after=`. Five causes were fixed on the way:

- Two Flux Kustomizations owned the sentinel's RoleBinding. One bound the
  pre-rename ServiceAccount `signalloom-stun-sentinel`, so `can-i list pods`
  flipped between yes and no. The binding now has one owner. The sentinel has
  no cluster-scoped grant.
- The sentinel now runs non-privileged, with a read-only root filesystem. It
  has four capabilities and mounts only the host cgroup tree and debugfs.
  `ebpf_probe_attached` reports all four tracepoints.
- The probe stamps kernel PIDs, which the sentinel cannot see on a kind node.
  The correlator now resolves each event to its pod by cgroup-v2 inode, not by
  PID.
- The correlator posted a single object. `signal-ingest` decodes an array of
  observations, so every post was a `400`. Both components now check one golden
  contract.
- Observations carried processing time. They now carry event time.

**Step 2** failed because no Dex subject mapped to tenant `kusari`. So no
product path could create the row it once passed on. The row had been inserted
outside the product. The Dex user `kusari-operator` and its tenant mapping fix
this. They are not deployed yet.

**Step 5** freezes the pod. The kernel reports `frozen 1`. The legacy reconciler
then thaws the pod about 14 s later. The Shared Pattern 4
`reconcile: disabled` annotation is not yet applied from a sentinel detection.
