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
  `WAIT_STAT site=… elapsed=… deadline=… ratio=… result=…`. After a run:
  ```bash
  sort -t= -k5 -rn /tmp/waitstats   # rank by ratio → exactly which deadlines to raise
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
signalloom-infra=13, signalloom-apps=9, and drift when resources are added).

---

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
