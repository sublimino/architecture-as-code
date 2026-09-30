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
| 2 Claim | `agent_registry` row for `kusari-agent` exists, is bound to tenant `kusari`, carries a `model_name`, and never contains the retired typo `kurasi`; hash derives to `4b53ab6b` | read-only `SELECT` + `scripts/derive_tenant_hash.py` |
| 3 Provoke | `POST /act/read-passwd` → 200 `{"action":"read-passwd","ok":true}` with `held_ms >= 50`, a real `tid`, `lines > 0`, and no file content in the body; `POST /act/read-shadow` → `attempted: true` | API-server pod proxy |
| 4 Detect | a `sys_enter_openat` observation against `/etc/passwd\|/etc/shadow` reaches `signal-ingest:8082`, normalized with `actor_id`, `pod_name`, `cgroup_path`, `tenant_id == kusari`, inside the correlation window | API-server service proxy |
| 5 Freeze | this pod's own `cgroup.events` reports `frozen 1`; Deployment **and** Pod carry `kustomize.toolkit.fluxcd.io/reconcile: disabled`; `restartCount == 0`; two distinct cAdvisor samples give exactly `0.000` mCPU; the frozen pod no longer answers traffic | kernel read on the node + kubelet cAdvisor proxy |

## Design decisions worth knowing

**No `kubectl exec` as a probe.** `exec` tunnels through the API server and
would keep answering after the network quarantine is applied, masking the very
failure Step 5 exists to catch. The single exception is Step 2's `SELECT` - there
is no `psql` on the host and the database is deliberately not exposed. It is
read-only and documented inline.

**No bare `sleep`.** Every wait is a deadline-bounded poll from
`scripts/lib/wait.sh`, so a slow machine is slow rather than red. Polled
predicates are exported shell functions, not command strings: `_wait_retry` runs
its argument through `bash -c`, and nesting the SQL inside that string put the
statement's own `'|'` literals in a position where they terminated the inner
`sh -c '...'`. Quoting belongs in code, where the shell parses it once.

**The cgroup is resolved by pod UID, never `find … | head -1`.** Appendix F.1
reads the first `kubepods` cgroup it finds on the node, which is an arbitrary
workload - on a shared cluster with other deliberately frozen agents, that
assertion passes on someone else's freeze state. The suite derives
`pod<UID>.slice` from the pod under test.

**Teardown thaws only the cgroup this suite froze.** For the same reason: a
blanket `for f in $(find /sys/fs/cgroup -name cgroup.freeze); do echo 0 > $f;
done` would silently thaw every deliberately frozen agent on `kind-osramp` and
destroy another card's state.

**The CPU flatline compares two genuinely distinct samples.** cAdvisor serves a
cached housekeeping sample; reading the same counter twice in quick succession
returns the same value whether the container is frozen or burning a full core.
The suite waits for cAdvisor's own timestamp field to advance, then requires the
counter to be unchanged.

**Every external dependency is injectable** - `SLDC_KUBECTL`, `SLDC_DOCKER`,
`WL_CONTEXT`, `HUB_CONTEXT`, `DB_CONTEXT`, `NODE`, `NS`, `EVIDENCE_DIR`,
`SLDC_OBS_WINDOW_MS` - which is what lets the mutation proof drive the real
suite against a fake cluster.

## Falsifiability (Shared Pattern 6)

`test/e2e-mutation-proof.sh` runs the real suite against a hermetic fake
kubectl/docker pair: once with baseline fixtures where all five steps pass, then
once per mutation, each breaking exactly one behaviour and expected to redden
exactly the step that guards it. 20 mutations plus the baseline, TAP-13 output,
no cluster needed:

`step1_not_ready`, `step1_dirty_restart`, `step2_no_row`, `step2_wrong_tenant`,
`step2_legacy_typo`, `step2_no_model`, `step3_act_failed`,
`step3_descriptor_not_held`, `step3_shadow_not_attempted`,
`step4_probe_removed`, `step4_not_sensitive`, `step4_stale_timestamp`,
`step4_wrong_tenant`, `step4_legacy_typo`, `step5_freeze_disabled`,
`step5_restart_h1_breach`, `step5_no_flux_suppression`,
`step5_no_pod_suppression`, `step5_cpu_still_burning`, `step5_still_serving`.

That matters more than usual here, because the live estate cannot currently pass
Steps 2, 4 and 5 (below). A proven-falsifiable suite makes a red live run a
finding about the estate rather than a suspicion about the suite.

## Provocation endpoints

`kusari-agent` gained three `POST`-only routes. Each answers a JSON envelope
whose first two fields are always `action` and `ok`.

| Route | Behaviour |
| :--- | :--- |
| `POST /act/read-passwd` | `open(2)` `/etc/passwd` **from the request's own OS thread** (`runtime.LockOSThread`), read it, hold the descriptor `ACT_HOLD` (default 100ms), report `bytes`/`lines`/`held_ms`/`pid`/`tid`. Never returns file content. |
| `POST /act/read-shadow` | The same against `/etc/shadow`. Reports `attempted: true` even when the file is absent - on a distroless image it is, and the `sys_enter_openat` is the signal, not the bytes. |
| `POST /act/cpu-burn` | Busy-loop `?threads=N` (default `GOMAXPROCS`, max 64) for `?duration=D` (default 5s, clamped to `ACT_BURN_MAX`, default 60s), each goroutine locked to its own OS thread. Answers only once the burn is over. |

The thread locking and the hold window exist because of a known failure mode: a
syscall issued from a helper thread that exits before the probe correlates it is
invisible to the sentinel.

`GET` on any `/act/*` route is `405` with `Allow: POST`; an unknown action is
`404`; bad `duration`/`threads` are `400` with `ok: false`.

## Known blockers on the live estate (2026-09-30)

Steps 1 and 3 pass live. Steps 2, 4 and 5 cannot, for causes that predate this
card and are recorded as P5-PRE blockers B1-B7.

**Step 4/5 - the in-sentinel correlator is starved of its pod index.** The
deployed `stun-sentinel` DaemonSet attaches its probes correctly
(`"event":"ebpf_probe_attached"`, tracepoints `sys_enter_openat`,
`sys_enter_openat2`, `sys_enter_execve`, `sys_enter_connect`), but its
ServiceAccount cannot list pods:

```
$ kubectl --context kind-osramp auth can-i list pods \
    --as=system:serviceaccount:fe-signalloom-agents:stun-sentinel -n fe-signalloom-agents
no
```

so the informer's pod map stays empty, and every sensitive `openat` is dropped
at `pkg/correlator/ebpf_correlator.go:481` (`if pod == nil { continue }`) before
normalization, before dispatch, and before the freeze. Three provocations
produced zero `sys_enter_openat` observations at `signal-ingest`, the pod's
`cgroup.events` reads `frozen 0`, and no `reconcile: disabled` annotation is
applied. The RBAC ships in the sentinel's own Flux slice, which is itself not
applying:

```
$ kubectl --context kind-osramp get kustomization agent-signalloom-stun-sentinel -n fe-signalloom-agents
False :: DaemonSet.apps "stun-sentinel" is invalid:
  spec.template.spec.containers[0].volumeMounts.mountPropagation: Forbidden:
  Bidirectional mount propagation is available only to privileged containers
```

**Step 2 - the claim binds the wrong tenant, and the database is not where the
proposal says.** Appendix F.1 queries `agent_registry` on
`kind-signalloom-hub`; that cluster runs no PostgreSQL (only SPIRE and the
router). At the real location (`kind-osramp`, `inf-signalloom/postgresql`) the
row reads:

```
kusari-agent|tenant-demo|claude-3-5-sonnet
```

Tenant `tenant-demo`, not `kusari` - a Shared Pattern 1 breach - and a
`model_name` of `claude-3-5-sonnet` for a workload labelled
`signalloom.ai/model: deterministic`, i.e. fabricated by autoclaim rather than
read from the pod labels. `DB_CONTEXT` exists so the suite can probe either
topology; the default follows the proposal.

None of these are test defects: each is reproduced by a named mutation in the
falsifiability matrix, and each fails live for a cause with a `file:line` or a
command-and-output behind it.
