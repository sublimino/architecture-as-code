# Cluster & registry debugging notes

Field notes for agents debugging the local KIND stack (foundation + Signal Loom +
CPAI). Written from a session that hit and fixed each of these. Pairs with
`make doctor` (`scripts/cluster-debug.sh`) — see the recommendations at the end.

## 1. ZOT registry crash-loop — `cache.db: permission denied`

**Symptom.** `make up` fails at `registry` / `zot-up` with
`kubectl rollout status deploy/zot --timeout=2m` → `timed out waiting for the
condition`. The zot pod is `CrashLoopBackOff` (or `Init:RunContainerError`).

**Diagnosis.**
```bash
kubectl -n registry get pods
kubectl -n registry logs -l app=zot -c zot --tail=30   # look for the real error
```
Root cause seen: `open /var/lib/zot/cache.db: permission denied`. Zot runs as
uid **65532** and writes its bolt cache to the host-backed volume
(`.cache/zot` on the host → `/var/local/osramp-zot-cache` in the node →
`/var/lib/zot` in the pod). If that persistent cache accumulates a `cache.db`
owned by a different uid — which happens after **concurrent or killed `make up`
runs** stamp it with mixed ownership — the chowned *directory* is writable but
the stale *file* inside is not, and zot exits 1 on startup.

**Recovery (fast).**
```bash
make zot-cache-reset          # clears the cache from inside the node + removes host .cache/zot
kubectl -n registry delete pod -l app=zot
source scripts/lib/wait.sh && wait_rollout zot -n registry 120
```
If it still crashes (a mount left in a bad state by live patching), the
deterministic fix is a clean cluster:
```bash
kind delete cluster --name osramp
rm -rf .cache/zot; docker volume rm -f osramp-zot-cache
make up
```

**Prevention.** Don't run two `make up`s at once against the same cluster —
they corrupt the shared persistent zot cache. The host `.cache/zot` is owned
`65532:65532 0750`, so you can't `ls` it as your user; that's expected, not the
bug. The bug is a stale `cache.db` inside it.

## 2. Pull-through registry mirror (base-image cache)

`scripts/registry-cache.sh` runs five host-side `registry:2` pull-through
proxies (docker.io, registry.k8s.io, ghcr.io, quay.io, mirror.gcr.io) on the
`kind` docker network, and `create-kind-cluster.sh` points the node's containerd
at them via `/etc/containerd/certs.d/<host>/hosts.toml`. They persist across
cluster recreations, so cold-start image pulls are served locally.

**Verify it is serving pulls** (not silently bypassed):
```bash
docker ps --filter name=registry-cache            # 5 proxies, all Up
docker exec osramp-control-plane cat /etc/containerd/certs.d/ghcr.io/hosts.toml  # non-empty
docker logs registry-cache-k8s 2>&1 | grep -c 'GET /v2'   # >0 means real pulls flowed through
```
Gotcha fixed here: writing `hosts.toml` needs `docker exec -i` (heredoc on
stdin) — without `-i` the file is silently empty and containerd bypasses the
mirror.

## 3. Resilient waits — `scripts/lib/wait.sh`

All ad-hoc `kubectl wait` / `rollout status` / `curl` poll loops are being
unified onto `scripts/lib/wait.sh` (vendored from `~/.andy_sync/includes/wait.sh`).
Key verbs: `wait_reachable`, `wait_tcp`, `wait_k8s_exists`, `wait_k8s_ready`,
`wait_flux_ready`, `wait_rollout`, `wait_pods_ready`. Principles: **deadline not
attempt-count**, **existence before condition** (fixes the cold-cluster race
where `kubectl wait` errors instantly on a not-yet-created object), exponential
backoff + jitter, per-attempt `timeout` hang fence.

**Debugging tunables (env):**
- `WAIT_DEADLINE_SCALE=10` — stretch every deadline for a saturated box; the
  same suite passes slowly instead of failing.
- `WAIT_SOFT_RATIO=0.6` — on crossing 60% of a deadline, a wait prints
  `⚠ slow: <site> still not ready after Xs of Ys … retry: <cmd>` and keeps
  waiting. The `retry:` command is copy-pasteable for manual poking.
- `WAIT_STAT_FILE=/tmp/waitstats` — every wait appends
  `WAIT_STAT site=… elapsed=… deadline=… ratio=… result=…`. After a run,
  export the same file and use `make doctor` to rank the five slowest waits:
  ```bash
   WAIT_STAT_FILE=/tmp/waitstats make doctor
  ```

## 4. `make up` cold-start convergence

`wait-reconciled.sh` (hardened) polls each foundation object for **existence
first**, then readiness — so a cold cluster where Flux hasn't created the infra
Kustomizations yet no longer FATALs the gate prematurely. Convergence to 10–14
Ready Kustomizations takes ~7 min cold, faster with the warm mirror. The long
pole is the monitoring stack (Prometheus operator installs the `ServiceMonitor`
CRD that trivy depends on); a `flux reconcile kustomization infra-configs -n
trivy-system` nudge resolves the last straggler if it lags.

## 5. Fleet `tenants` Kustomization build failure → no ResourceSets

**Symptom.** `make up` hangs in the wait phase; `kubectl get resourceset -A`
shows only `flux-operator` — `policies`/`infra`/`signalloom-*` never appear.
```bash
kubectl -n flux-system get kustomization tenants -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
# kustomize build failed: replace operation does not apply: doc is missing path: /spec/resources/9/spec/verify
```
**Cause.** `d2-osramp-fleet/tenants/local/kustomization.yaml` JSON6902-patches
each ResourceSet's OCIRepository to inject a cosign `verify` block using
`op: replace /spec/resources/N/spec/verify`. `replace` requires the `verify`
key to already exist; if the OCIRepository has no `verify` stub, or the resource
list changed and index `N` shifted, the whole `tenants` build aborts → the
ResourceSets are never created → the entire foundation stalls.

**Fix.** Use `op: add` instead of `op: replace` for the `verify` path (sets it
whether or not it pre-exists), and confirm each index still points at the
OCIRepository (the indices differ per ResourceSet, e.g. infra=5,
signalloom-infra=13, signalloom-apps=10, and drift when resources are added).

---

## 6. Isolated remote Signal Loom CI (VM2)

Use VM2 only for remote reproduction so VM1 and a developer's Kind cluster stay
untouched. The CI targets namespace every VM2 artifact under `*-2`:

```bash
make ci-status-2                 # read-only VM state
make ci-gcp-2                    # SCP snapshot, clean VM2 Kind cluster, run all stages
make ci-ssh-2                     # interactive IAP diagnosis after a failed run
make ci-report-2                 # inspect the collected OpenReports result
```

The run is intentionally stateful only inside VM2:

- VM: `signalloom-ci-2` in `europe-west2-a`.
- checkout: `/home/ci/osramp-demo-ci-2`.
- reports: `/home/ci/reports-signalloom-ci-2`, collected into `ci-reports-2/`.
- pipeline log: `/home/ci/ci-pipeline-ci-2.log`.

Each run replaces only VM2's remote checkout with a fresh archive of the local
working tree before the pipeline starts. This includes uncommitted changes and
removes stale remote paths; it does not modify VM1 or any local cluster.

Each of the eight test stages is capped at 900 seconds by default. A timed-out
stage exits `124`, appends `TIMEOUT` to its `stage*.{tap,txt}` artifact, and the
remaining stages continue. Override only when diagnosing a known slow host:
`CI_STAGE_TIMEOUT_SECONDS=1200 make ci-gcp-2`.

Debug in this order: run `make ci-report-2`, read `summary.json` and failing
`stage*.{tap,txt}` files; then use `make ci-ssh-2` to inspect
`/home/ci/ci-pipeline-ci-2.log`; inspect Flux (`kubectl get kustomizations -A`)
before workload pods; then inspect the exact controller or pod logs. Rerun
`make ci-gcp-2` only after applying a minimal, evidence-backed local change;
its SCP snapshot is the source under test. On a pass VM2 suspends automatically.
Do not run `make teardown`, `make up`, or any destructive cleanup against a
shared local cluster while another process uses it. Once VM2 passes, recreate
or repair the local cluster as needed and run the same full suite locally.

## 7. Cosign local signing — no transparency log

Local mode signs every OCI artifact and workload image with the key pair from
`make signing-keys` and must **never** contact the public transparency log
(Rekor) — it's an offline demo.

**How it's enforced (cosign v3).** `make signing-keys` also generates a
no-transparency-log SigningConfig at `.keys/signing-config.json`:
```bash
cosign signing-config create \
  --no-default-rekor --no-default-fulcio --no-default-oidc --no-default-tsa \
  --out .keys/signing-config.json
# => {"mediaType":"…signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}
```
Every `cosign sign` call passes `--signing-config .keys/signing-config.json`
(the Makefile `cpai-images` target and `scripts/{push-local,build-sign-dashboard,
admission-demo,revocation-demo}.sh`, each with a create-if-missing fallback for
standalone runs).

**Why not `--tlog-upload=false`?** That flag is deprecated in cosign v3 and spams
`Flag --tlog-upload has been deprecated…` on every sign. **Do not "fix" the
warning by deleting the flag** — without it (or the no-tlog signing-config)
cosign uploads to the public Rekor and prints `tlog entry created with index:
…`. The empty-`rekorTlogConfig` signing-config is the non-deprecated replacement
that keeps signing key-only and offline. The `dashboard-supplychain.bats` test
guards this: it asserts `--signing-config` is present and `--tlog-upload` is
absent.

**Verify a signature (offline):**
```bash
cosign verify --key .keys/cosign.pub --insecure-ignore-tlog=true \
  --allow-insecure-registry <ref>@<digest>
```

## 8. Probes that report a confident answer they did not earn

The recurring failure in this repo is not a broken check — it is a check that
**cannot fail**, or one that reports a cause it never measured. Root `AGENTS.md`
states the rule: *a wait that can never succeed and a gate that always passes are
the same bug wearing different hats.* Concrete instances, all found live:

Several of the entries below (the silent RoleBinding, the label-blind
NetworkPolicy, the API path answered by `index.html`) are layers of one larger
failure — a finished backend service that was never deployed. The checklist that
prevents it is [`deploying-a-backend-service.md`](deploying-a-backend-service.md);
what follows is why each layer lies about itself when you go looking.

### `nc` exit codes cannot distinguish denial from breakage

`busybox:1.36` returns **exit 1** for a blackholed IP *and* for an unresolvable
host (`nc: bad address`), a missing binary, and a dead container. Only stderr
differs. Any probe inspecting the status alone passes on any breakage:

```bash
nc -z -w 2 240.0.0.1 9999     # exit 1  — a real block
nc -z -w 2 nope.invalid 9999  # exit 1  — DNS failure, indistinguishable
```

Capture stderr and classify. `scripts/agent-trust-local.sh` `expect_tcp` reports
`UNVERIFIED` for breakage rather than counting it as a denial.

### A brand-new pod is briefly UNCONFINED

The CNI programs a pod's NetworkPolicy rules a moment **after** the container
starts. A denial asserted at t=0 measures that gap, not the policy —
`planner-egress-denied` reported "arbitrary egress unexpectedly reachable" on
every run while an identically-labelled pod given 20s was correctly denied.

Fix with a **positive control**: reach something the policy permits (kube-dns
TCP/53 is allowed from every agent-trust namespace) to prove the dataplane is
programmed, *then* assert the denial. Time out to `UNVERIFIED`, never a pass. A
bare retry-until-denied is worse than the original bug — it makes a real hole
indistinguishable from "not ready yet".

### NetworkPolicies select on labels, not on identity

A pod carrying the right ServiceAccount and SPIFFE ID still gets dropped if it
lacks the label the policy names. The Fleet Manager 504 was exactly this: the
policy admitted `app.kubernetes.io/part-of=signalloom`, the dashboard carries
only `app.kubernetes.io/name=dashboard-signalloom`. **A NetworkPolicy naming a
label the sender does not have is a closed door wearing a timeout's clothes.**

Corollary: borrowing a workload's identity label captures every *other* selector
that label feeds — Services, `kubectl get pods -l`, PDBs. Give probes
`app.kubernetes.io/component: probe` and exclude it where a lookup requires
exactly one pod.

### A RoleBinding to a non-existent ServiceAccount is legal and SILENT

`fleet-manager`'s binding named `namespace: default` for an SA living in
`fe-signalloom`. It binds nothing, so every pod list/patch 403s — and client-go
surfaces that as an **empty result**, not a permission error. The page renders an
empty fleet with no reason given. Always verify the subject namespace matches
where the Deployment actually runs.

### An API path with no nginx `location` returns `index.html` with 200 OK

`res.ok` is **true** for the SPA fallback, so a `fetch` goes straight to
`res.json()` and throws `Unexpected token '<', "<!doctype "...`. That names the
symptom and hides the cause. `d2-signalloom/test/dashboard-route-collisions.bats`
guards both directions — proxy prefixes shadowing SPA routes, and every nginx
upstream having a matching dashboard egress rule. It caught the Fleet egress gap
the moment the proxy was added.

### `kubectl -o jsonpath='{.items[0]...}'` with no matches EXITS 0

It prints `error: ... array index out of bounds` on **stdout**. A naive
`else` branch reads that error text as data. Establish the object exists first.

### Reading the demo's own probe output

Probe CronJobs use `terminationMessagePolicy: File`, so `kubectl logs` on a
failed probe is **empty**. The verdict is in the termination message:

```bash
kubectl -n agent-trust-acme-payments get pod <probe-pod> \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.message}'
```

## Recommendations for `make doctor` (`scripts/cluster-debug.sh`)

The current report covers unhealthy pods, Flux Kustomizations/ResourceSets,
image failures, and events. Add these high-signal, learned-the-hard-way checks:

1. **ZOT cache-permission detector.** When the `registry/zot` pod is unhealthy,
   grep its logs for `permission denied` / `cache.db` and, on match, print the
   exact recovery: `make zot-cache-reset && kubectl -n registry delete pod -l
   app=zot`. Also check the host cache: `stat -c '%u:%a' .cache/zot` (expect
   `65532:750`) and flag drift.

2. **"Expected ResourceSet missing" check.** If `flux-system` has a
   Kustomization whose `Ready=False` message contains `kustomize build failed`,
   print that message verbatim (it names the actionable `/spec/resources/N/…`
   path) and flag that downstream ResourceSets (`policies`, `infra`,
   `signalloom-*`) are absent. This is the single most confusing failure — the
   symptom (waits hanging) is far from the cause (a patch index/verify error).

3. **Pull-through mirror health.** Report the five `registry-cache-*` proxies'
   status and whether the node's `certs.d/*/hosts.toml` files are non-empty —
   an empty hosts.toml silently disables the cache and slows every cold start.

4. **WAIT_STAT ranking.** If `WAIT_STAT_FILE` exists from the last run, print the
   top-5 waits by `ratio=` — a deterministic list of which deadlines are tight,
   far better than inferring it from retry noise.

5. **Wire it in:** `make doctor` should stay a read-only triage (no mutations),
   but each finding should end with a copy-pasteable recovery command, matching
   the existing `recommend "…"` pattern.
