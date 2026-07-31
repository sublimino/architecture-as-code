# Plan: Fix local dev cluster, then pass remote CI

## Context

The GCP CI VM ran the full 8-stage pipeline (attempt 10) and scored 3/8 pass. The 5 failures traced to:
- **Stage 1**: no `.git/` on VM (kustomize security boundary) — fixed in `vm-pipeline.sh`
- **Stage 4**: `go` not in VM PATH — fixed with GOBIN + `/usr/local/bin` writable
- **Stages 6-8**: cascading from two fleet issues:
  - HTTPRoute RBAC: `flux` SA in `fe-signalloom` can't manage `gateway.networking.k8s.io/httproutes` — **fixed** in `signalloom.yaml` (Role + RoleBinding added)
  - Kustomize patch index: new RBAC resources shifted the OCIRepository from index 5 to 7 — **fixed** in `kustomization.yaml`

All fixes are committed locally but the local Kind cluster still runs the OLD fleet artifact (pushed days ago). The local cluster is healthy (all kustomizations `True`), stages 1 and 4 pass locally.

## Steps

### Step 1: Push the updated fleet to local Zot

The RBAC + patch-index fixes are in `d2-osramp-fleet/tenants/local/` which is part of the fleet OCI artifact. Push it to the local Zot so Flux reconciles the new version.

```bash
cd /home/andy/src/cp/osramp-demo
make push-local-foundation    # re-push fleet artifact to Zot
make push-local-signalloom    # re-push signalloom artifacts
```

Then wait for Flux to reconcile (the `tenants` Kustomization will apply the updated signalloom ResourceSets with the new RBAC):

```bash
kubectl -n flux-system wait kustomization/tenants --for=condition=ready --timeout=5m
kubectl -n fe-signalloom wait kustomization/apps --for=condition=ready --timeout=5m
```

### Step 2: Verify all 8 stages locally

Run each stage individually, capture pass/fail:

```bash
# Stage 1: Static topology
make -C d2-signalloom test

# Stage 2: API contracts
cd d2-signalloom/apps/fe-signalloom/src && uv run --python 3.12 --with pytest --with pytest-asyncio --with-requirements requirements.txt python -m pytest tests -q

# Stage 3: Fake integrations
PYTHONPATH=d2-signalloom/apps/fake-integration-proxy python3 -m pytest d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py -q

# Stage 4: Dashboard API
cd tools/demo-console && go test ./...

# Stage 5: Harness contract
bats test/signalloom-test-1-harness.bats

# Stage 6: Flux convergence
./scripts/signalloom-local.sh verify

# Stage 7: Runtime negatives
bats d2-signalloom/test/runtime.bats d2-signalloom/test/test-1-runtime.bats

# Stage 8: Browser journey
./scripts/acceptance-test.sh signalloom-test-1.spec.ts
```

### Step 3: Fix any local failures

If stage 6 fails: check `kubectl get kustomizations -A` — the new RBAC should have resolved the HTTPRoute issue. If `fe-signalloom/apps` still fails, inspect with `kubectl describe kustomization apps -n fe-signalloom`.

If stages 7-8 fail: these need live services. Check pods in `fe-signalloom`, `inf-signalloom`, `ingress` namespaces. Port-forwards need to work for the Gateway, Dex, and dashboard.

### Step 4: Push fixes to VM and rerun

```bash
cd /home/andy/src/cp/osramp-demo
tar --exclude='.git' --exclude='node_modules' --exclude='.cache' --exclude='ci-reports' --exclude='worktrees' -czf /tmp/osramp-demo-ci.tar.gz .

# Push code
SSH_AUTH_SOCK= gcloud compute ssh signalloom-ci ... --command="sudo rm -rf /home/ci/osramp-demo && ..." < /tmp/osramp-demo-ci.tar.gz

# Resume and run
./scripts/ci/gcp-ci.sh run
```

### Step 5: On pass — suspend VM

`gcp-ci.sh run` automatically suspends on pass. If it fails, SSH in to debug, fix, repush, rerun.

## Files to modify

None anticipated — all fixes are already committed. This plan is about verification and execution.

## Verification

- Local: all 8 stages pass individually
- Remote: `summary.json` shows `"overall": "PASS"` with 8/8 stages passed
- VM: suspended after successful run
- `ci-reports/signalloom-ci-report.yaml` has 0 errors in the OpenReports summary
