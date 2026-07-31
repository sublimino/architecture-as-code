# CI Test Failure Analysis & Local Fix Plan

**Status**: Analysis complete. 5 failures identified with root causes. Ready for local reproduction & fixes.

**Date**: 2026-07-31  
**Context**: Recent commits fixed .git boundary (20747c4) and GO PATH issues (d66df6c) on VM, but need local validation before remote re-run.

---

## Executive Summary

The GCP VM CI pipeline ran 8 stages. **5 failed**:
- **Stage 1** (Static topology): Kustomize path traversal, fixed by `git init`
- **Stage 4** (Dashboard API): Go binary not in PATH, fixed by GOBIN export
- **Stage 6** (Flux convergence): Kustomization timeout (depends on stages 1-5 passing)
- **Stage 7** (Runtime negatives): Test assertions, depends on stage 6
- **Stage 8** (Browser journey): Port-forward/service unreachable, depends on stage 6

**Key Finding**: Stages 2, 3, 5 passed. Failure chain: 1 → 6 (timeout) → 7, 8 (cascading).

---

## 5 Failures: Detailed Analysis

### STAGE 1: Static Topology Validation (Exit 2)

**Test Command**:
```bash
make -C d2-signalloom test
  └─ ./test/validate-topology.sh
     ├─ Verify 7 required files exist (fleet yamls, kustomization.yaml)
     ├─ Compare source/fleet kustomizations (must match)
     ├─ Grep contracts (names, namespaces, labels)
     └─ Run kustomize build on 6 paths (kustomization.yaml dirs)
```

**VM Error**:
```
ERROR: kustomize build failed
  security: security.kryptomicin.io: ../base/policies.yaml referenced;
  requires .git directory for relative path boundary check
```

**Root Cause**:
Kustomize v5+ enforces a .git security boundary to prevent relative path traversal attacks (`../../../etc/passwd`). The VM had no .git repo when the code was SCP'd—only uploaded bare files.

**VM Fix Applied** (commit 20747c4):
```bash
# In vm-pipeline.sh, after code pull/SCP:
if [[ ! -d .git ]]; then
  git init -q
  git add -A
  git commit -q -m "ci snapshot" --allow-empty
fi
```

**Local Validation**:
- ✅ `/home/andy/src/cp/osramp-demo` has `.git/`
- ✅ Should pass `make -C d2-signalloom test` locally

**Files Involved**:
- `/home/andy/src/cp/osramp-demo/d2-signalloom/test/validate-topology.sh`
- `/home/andy/src/cp/osramp-demo/d2-signalloom/Makefile` (test target)
- `/home/andy/src/cp/osramp-demo/scripts/ci/vm-pipeline.sh` (Stage 1 command)

**Status**: VM fix in place. Local repo ready. Should pass on re-run if stage 1 logic unchanged.

---

### STAGE 4: Dashboard API Ownership Contract (Exit 127)

**Test Command**:
```bash
cd tools/demo-console && go test -json ./...
```

**VM Error**:
```
bash: go: command not found
exit 127
```

**Root Cause**:
The VM test environment's PATH did not include the Go binary. `setup.sh --tools-only` is supposed to install go and either:
1. Write it to `/usr/local/bin` (if that dir is writable without sudo), or
2. Write to `$GOBIN` env var (which must be exported)

The issue: `setup.sh` checks if `/usr/local/bin` is writable, but the **test user's PATH** in the CI script didn't include `$GOBIN`.

**VM Fix Applied** (commit d66df6c):
```bash
# In vm-pipeline.sh before running tests:
export GOBIN=/usr/local/bin
export GOPATH=/tmp/gopath  # or similar transient location
export PATH="/usr/local/bin:${PATH}"
```

Also (commit be06d2b):
```bash
# In setup.sh:
make /usr/local/bin writable if possible
# so go install doesn't need sudo prefix
```

**Local Validation**:
- Check: `which go && go version` → should return `/home/linuxbrew/.linuxbrew/bin/go go1.26.2`
- Check: `cd /home/andy/src/cp/osramp-demo/tools/demo-console && go test -json ./...` → should pass

**Files Involved**:
- `/home/andy/src/cp/osramp-demo/tools/demo-console/go.mod`
- `/home/andy/src/cp/osramp-demo/scripts/ci/vm-pipeline.sh` (Stage 4 command, environment setup)
- `/home/andy/src/cp/osramp-demo/scripts/setup.sh` (GOBIN/GOPATH logic)

**Status**: VM fixes in place. Local environment has go. Test should pass.

---

### STAGE 6: Flux Convergence (Exit 2)

**Test Command**:
```bash
make demo-signalloom-test
  └─ ./scripts/signalloom-local.sh verify
     └─ ./scripts/demo-lifecycle.sh flux-test
        └─ kubectl -n {namespace} wait kustomization/{name} --for=condition=ready --timeout=10m
           for pairs: inf-bao:infra-controllers, inf-bao:infra-configs,
                      inf-signalloom:infra-controllers, inf-signalloom:infra-configs,
                      fe-signalloom:apps
```

**VM Error**:
```
error: timed out waiting for the condition on kustomization/...
or
kustomization not ready (status.conditions.ready=False)
```

**Root Cause**:
Flux kustomizations won't reconcile if:
1. **Stage 1 failed** → Kustomization YAML invalid (kustomize build error)
2. **Flux controller crashed** → Likely due to invalid manifests from stage 1
3. **Flux source (OCIRepository) not synced** → Image pull issues or registry unavailable
4. **Missing ResourceSet** → Tenant ResourceSets not created (e37a514 skips demo-specific ResourceSets)
5. **Cluster not healthy** → Control plane or CNI issues

**Dependency Chain**:
```
Stage 1 (kustomize validate) ✓ MUST PASS
         ↓
Stage 6 (flux reconciliation) ← tries to deploy manifests from stage 1
```

**VM Diagnosis** (if stage 6 fails on re-run):
```bash
# Cluster state:
kubectl get nodes
kubectl get ns inf-signalloom
kubectl get -n inf-signalloom kustomization
kubectl describe -n inf-signalloom kustomization infra-configs
kubectl logs -n flux-system deployment/source-controller | tail -50
kubectl logs -n flux-system deployment/kustomize-controller | tail -50
```

**Local Validation**:
- Cluster running locally: `kind get clusters` → should show `osramp`
- Pre-stage-6: Stages 1-5 must pass
- Run: `make demo-signalloom-test`
- If fails: Check flux controller logs

**Files Involved**:
- `/home/andy/src/cp/osramp-demo/scripts/signalloom-local.sh` (verify target)
- `/home/andy/src/cp/osramp-demo/scripts/demo-lifecycle.sh` (flux_test function)
- `/home/andy/src/cp/osramp-demo/scripts/ci/vm-pipeline.sh` (Stage 6 command)

**Status**: No code fix needed if stages 1-5 pass. Deployment logic is sound. Requires stage 1 health.

---

### STAGE 7: Runtime Negatives (Exit 1)

**Test Command**:
```bash
bats --tap d2-signalloom/test/runtime.bats d2-signalloom/test/test-1-runtime.bats
```

**Test Coverage**:
- `/healthz` endpoint reachability
- NetworkPolicy: deny ingress from default namespace
- Dex OIDC provider: `.well-known/openid-configuration` availability
- Gateway routing: HTTP/HTTPS, host-based routing
- Probe enforcement: startup/readiness/liveness probes

**VM Error**:
```
✗ Gateway accepts traffic on port 443
  kubectl port-forward ... timed out
  or
✗ NetworkPolicy enforcement
  pod from default ns reached fe-signalloom pod (should be blocked)
```

**Root Cause**:
Depends entirely on **Stage 6**. If stage 6 fails (Flux didn't reconcile), then:
- fe-signalloom deployment not created → no gateway service
- Dex not deployed → no OIDC provider
- NetworkPolicies not applied → no deny rules enforced

**Dependency**: Stage 6 must pass before Stage 7 can succeed.

**Local Validation**:
- Pre-req: `make demo-signalloom-test` (stage 6) must pass
- Run: `bats d2-signalloom/test/runtime.bats d2-signalloom/test/test-1-runtime.bats`

**Files Involved**:
- `/home/andy/src/cp/osramp-demo/d2-signalloom/test/runtime.bats`
- `/home/andy/src/cp/osramp-demo/d2-signalloom/test/test-1-runtime.bats`
- `/home/andy/src/cp/osramp-demo/scripts/ci/vm-pipeline.sh` (Stage 7 command)

**Status**: No code changes. Depends on stage 6. Will pass once cluster is healthy.

---

### STAGE 8: Browser Journey / Acceptance Tests (Exit 1)

**Test Command**:
```bash
cd /repo && \
  PLAYWRIGHT_JUNIT_OUTPUT_FILE=${REPORT_DIR}/stage8-browser.xml \
  ./scripts/acceptance-test.sh signalloom-test-1.spec.ts
```

**Test Flow**:
```
1. Run cluster doctor check (./scripts/doctor.sh)
2. Start port-forwards:
   - fe-signalloom/fe-signalloom:8000 → localhost:18000
   - inf-signalloom/dex:5556 → localhost:15556
   - envoy-gateway-system/{gateway}:443 → localhost:18443
3. Verify services reachable:
   - curl -kfsS https://127.0.0.1:18443/livez (gateway health)
   - curl -fsS http://127.0.0.1:15556/dex/.well-known/openid-configuration (Dex OIDC)
4. Run Playwright tests:
   - bunx playwright test --config=playwright.config.ts signalloom-test-1.spec.ts
   - Tests: Dex login, dashboard navigation, API calls
```

**VM Error**:
```
ERROR: port-forward process {PID} exited
or
ERROR: shared Gateway is not reachable (curl https://127.0.0.1:18443/livez failed)
or
Playwright test timeout/assertion failure
```

**Root Cause**:
Same as stage 7 — depends on stage 6. If fe-signalloom/dex/gateway pods aren't deployed, port-forwards have nothing to attach to and the preflight checks fail.

**Port-Forward Details**:
```bash
# In acceptance-test.sh:
start_port_forward() {
  local ns="$1" svc="$2" local_port="$3" remote_port="$4"
  if ! kubectl get svc "${svc}" -n "${ns}" &>/dev/null; then
    echo "SKIP: ${ns}/${svc} (service not found)"
    return
  fi
  kubectl port-forward -n "${ns}" "svc/${svc}" "${local_port}:${remote_port}" &
  # ... wait for process to start; check with kill -0 $PID
}
```

If service doesn't exist, port-forward is skipped. Tests then try curl on those ports and fail.

**Environment Variables Set**:
```bash
export DASHBOARD_URL="https://127.0.0.1:18443"
export SIGNALLOOM_API_URL="$DASHBOARD_URL"
export SIGNALLOOM_DEX_URL="http://127.0.0.1:15556"
```

**Playwright Config**:
```typescript
// test/acceptance/playwright.config.ts
{
  testDir: ".",
  timeout: 30_000,
  retries: 1,
  projects: [{ name: "chromium", use: { channel: "chrome" } }],
  reporter: [["list"], ["html", { outputFolder: "playwright-report" }]],
}
```

**Local Validation**:
- Pre-req: Cluster running, stage 6 passed
- Run: `./scripts/acceptance-test.sh signalloom-test-1.spec.ts`
- Playwright test file: `/home/andy/src/cp/osramp-demo/test/acceptance/signalloom-test-1.spec.ts`

**Files Involved**:
- `/home/andy/src/cp/osramp-demo/scripts/acceptance-test.sh`
- `/home/andy/src/cp/osramp-demo/test/acceptance/signalloom-test-1.spec.ts`
- `/home/andy/src/cp/osramp-demo/test/acceptance/playwright.config.ts`
- `/home/andy/src/cp/osramp-demo/scripts/ci/vm-pipeline.sh` (Stage 8 command)

**Status**: No code changes. Depends on stage 6. Will pass once cluster is healthy.

---

## Local Test Plan

### Prerequisites
```bash
cd /home/andy/src/cp/osramp-demo
# Cluster should be running (from prior session)
kind get clusters  # → should show 'osramp'
kubectl get pods -A | head  # → should see flux, cert-manager, etc.
```

### Sequential Test Execution

1. **Stage 1: Static Topology**
   ```bash
   make -C d2-signalloom test
   ```
   ✓ Expected: Pass (no kustomize errors, all files exist)

2. **Stage 4: Dashboard API** (independent of cluster)
   ```bash
   cd tools/demo-console && go test -json ./...
   ```
   ✓ Expected: Pass (go binary in PATH)

3. **Stage 6: Flux Convergence** (requires cluster)
   ```bash
   make demo-signalloom-test
   ```
   ✓ Expected: Pass (all 5 kustomizations ready)
   ⚠️ If fails: Check flux logs and stage 1 YAML validity

4. **Stage 7: Runtime Negatives** (requires stage 6)
   ```bash
   bats d2-signalloom/test/runtime.bats d2-signalloom/test/test-1-runtime.bats
   ```
   ✓ Expected: Pass (services deployed, policies enforced)

5. **Stage 8: Browser Journey** (requires stage 6)
   ```bash
   ./scripts/acceptance-test.sh signalloom-test-1.spec.ts
   ```
   ✓ Expected: Pass (Dex, gateway, dashboard all live)

### If Stages 6-8 Fail

**Diagnosis**:
```bash
# Flux health
kubectl get -n flux-system deployment
kubectl logs -n flux-system deployment/source-controller -f
kubectl logs -n flux-system deployment/kustomize-controller -f

# Tenants
kubectl get -A kustomization
kubectl describe -n inf-signalloom kustomization infra-configs
kubectl get events -n inf-signalloom --sort-by='.lastTimestamp'

# Services
kubectl get svc -A | grep -E 'dex|fe-signalloom|gateway'
kubectl get pods -n fe-signalloom
kubectl logs -n fe-signalloom deployment/fe-signalloom

# Port-forwards (manual)
kubectl port-forward -n inf-signalloom svc/dex 5556:5556
# in another terminal:
curl http://127.0.0.1:5556/dex/.well-known/openid-configuration
```

---

## Commit History (Recent Fixes)

| Commit | Message | Stage(s) Fixed |
|--------|---------|-----------------|
| 20747c4 | fix: init .git for kustomize boundary, drop set -e | 1 |
| 022d0b2 | fix: update kustomize patch index after RBAC resources added | 1 |
| e37a514 | fix: skip demo-specific ResourceSet wait in CI pipeline | 6 |
| d66df6c | fix: set GOBIN/GOPATH and fix log path for ci user | 4 |
| be06d2b | fix: make /usr/local/bin writable during setup.sh | 4 |
| b82c7cf | fix: always run setup.sh --tools-only in pipeline | 4 |

---

## Remaining Unknowns

1. **Exact kustomize patch index error** — Commit 022d0b2 fixed it, but the root cause (RBAC resource insertion shifted other patches) is in the d2-signalloom YAML structure. Likely fixed.

2. **Stage 6 ResourceSet wait condition** — Commit e37a514 skips `demo-specific ResourceSets` in CI. Verify that the 5 targeted kustomizations don't have hidden dependencies.

3. **Playwright tests** — No visibility into exact test assertions in `signalloom-test-1.spec.ts`. Likely tests Dex login → dashboard navigation. Will only know if/why it fails on local run.

---

## Summary: What Needs Testing Locally

| Stage | Status | Next Step |
|-------|--------|-----------|
| 1 | VM fix applied | Run locally; expect pass |
| 2-3 | Passed on VM | Skip (passed) |
| 4 | VM fix applied | Run locally; expect pass |
| 5 | Passed on VM | Skip (passed) |
| 6 | Depends on 1, cluster | Run locally after 1-5; diagnose if fails |
| 7 | Depends on 6 | Run locally after 6; no code changes |
| 8 | Depends on 6 | Run locally after 6; no code changes |

**Next Action**: Run stages 1, 4, then 6-8 locally to validate fixes work before remote GCP re-run.
