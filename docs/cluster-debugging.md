# Cluster & Registry Debugging Notes

These field notes help engineers debug the local Kind cluster foundation and application slices.
Use these notes alongside `make doctor` (`scripts/cluster-debug.sh`).

## 1. ZOT Registry Crash-Loop — `cache.db: permission denied`

**Symptom**: `make up` fails during `zot-up` with timeout:
`kubectl rollout status deploy/zot --timeout=2m` returns `timed out waiting for the condition`.
The ZOT pod enters `CrashLoopBackOff` or `Init:RunContainerError`.

**Diagnosis**:
Run these commands to inspect pod status and logs:
```bash
kubectl -n registry get pods
kubectl -n registry logs -l app=zot -c zot --tail=30
```

Root cause: `open /var/lib/zot/cache.db: permission denied`.
ZOT runs under UID 65532 and writes its bolt cache to `.cache/zot` on the host.
If concurrent or cancelled `make up` runs alter file ownership, ZOT cannot open `cache.db`.
The process exits with code 1 during startup.

**Recovery**:
Execute this fast recovery sequence:
```bash
make zot-cache-reset
kubectl -n registry delete pod -l app=zot
source scripts/lib/wait.sh && wait_rollout zot -n registry 120
```

If crashes continue, reset the cluster completely:
```bash
kind delete cluster --name osramp
rm -rf .cache/zot; docker volume rm -f osramp-zot-cache
make up
```

**Prevention**:
Do not run concurrent `make up` commands against the same cluster.
Host directory `.cache/zot` requires ownership `65532:65532` and permissions `0750`.

## 2. Pull-Through Registry Mirror (Base-Image Cache)

`scripts/registry-cache.sh` runs five pull-through container proxies on the `kind` Docker network.
`create-kind-cluster.sh` configures containerd using `/etc/containerd/certs.d/<host>/hosts.toml`.
These proxies persist across cluster resets to accelerate cold-start image downloads.

**Verification**:
Verify that the proxy containers run and handle requests:
```bash
docker ps --filter name=registry-cache
docker exec osramp-control-plane cat /etc/containerd/certs.d/ghcr.io/hosts.toml
docker logs registry-cache-k8s 2>&1 | grep -c 'GET /v2'
```

Caution: You must write `hosts.toml` using `docker exec -i`.
Without `-i`, the file writes empty and containerd bypasses the mirror.

## 3. Resilient Waits — `scripts/lib/wait.sh`

The platform uses `scripts/lib/wait.sh` for all polling operations.
Key functions include `wait_reachable`, `wait_tcp`, `wait_k8s_ready`, `wait_flux_ready`, and `wait_rollout`.
Core principles:
- Use absolute time deadlines instead of loop counts.
- Verify resource existence before evaluating status conditions.
- Apply exponential backoff with jitter.
- Enforce per-attempt execution timeouts.

**Debugging Variables**:
- `WAIT_DEADLINE_SCALE=10`: Multiplies deadlines for heavily loaded hosts.
- `WAIT_SOFT_RATIO=0.6`: Logs warning and retry commands when 60% of deadline elapses.
- `WAIT_STAT_FILE=/tmp/waitstats`: Records wait metrics for performance analysis.
  Analyze slowest operations with:
  ```bash
  WAIT_STAT_FILE=/tmp/waitstats make doctor
  ```

## 4. `make up` Cold-Start Convergence

`wait-reconciled.sh` verifies object existence before checking status conditions.
Cold bootstrap takes approximately seven minutes.
The monitoring stack requires the longest startup time.
Prometheus operator must install the `ServiceMonitor` CRD before Trivy reconciles.
If reconciliation lags, run:
```bash
flux reconcile kustomization infra-configs -n trivy-system
```

## 5. Fleet `tenants` Kustomization Build Failure

**Symptom**: `make up` hangs during resource synchronization.
`kubectl get resourceset -A` shows only `flux-operator`.
Downstream ResourceSets never appear.
Inspect error messages with:
```bash
kubectl -n flux-system get kustomization tenants -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
```

**Cause**: `d2-osramp-fleet/tenants/local/kustomization.yaml` patches the OCIRepository.
Using `op: replace /spec/resources/N/spec/verify` fails if the target path is missing.
When array index `N` shifts, Kustomize build fails and Flux halts reconciliation.

**Fix**: Use `op: add` instead of `op: replace` for the verify path.
Verify that array index numbers match actual OCIRepository positions.

---

## 6. Isolated Remote CI (VM2)

Use VM2 to reproduce remote CI failures without modifying local clusters or VM1.
CI targets isolate artifacts under the `-2` suffix:

```bash
make ci-status-2                 # Inspect remote VM state
make ci-gcp-2                    # Deploy tree snapshot, recreate Kind, run stages
make ci-ssh-2                     # Open interactive SSH session via IAP
make ci-report-2                 # Collect and inspect test reports
```

Execution properties:
- VM: `signalloom-ci-2` in `europe-west2-a`.
- Checkout: `/home/ci/osramp-demo-ci-2`.
- Reports: `/home/ci/reports-signalloom-ci-2`, collected into `ci-reports-2/`.
- Pipeline log: `/home/ci/ci-pipeline-ci-2.log`.

Each run archives the local working tree and deploys it to VM2.
This process includes uncommitted modifications and removes obsolete remote files.

Test stages have a default timeout of 900 seconds.
Timed-out stages exit with code 124 and mark reports with `TIMEOUT`.
Adjust timeouts with:
`CI_STAGE_TIMEOUT_SECONDS=1200 make ci-gcp-2`.

Debug pipeline failures in this order:
1. Run `make ci-report-2` and review `summary.json`.
2. Inspect failing `stage*.tap` files.
3. Open an SSH session with `make ci-ssh-2` and check `/home/ci/ci-pipeline-ci-2.log`.
4. Check Flux state with `kubectl get kustomizations -A`.
5. Check pod logs for failing workloads.
6. Commit minimal local fixes and rerun `make ci-gcp-2`.

The VM suspends automatically after all stages pass.
Do not run destructive cleanup commands on shared local clusters while other tests run.

## 7. Cosign Local Signing Without Transparency Logs

Local mode signs OCI artifacts and container images with keys from `make signing-keys`.
Offline environments must never upload records to the public Rekor transparency log.

**SigningConfig Configuration**:
`make signing-keys` creates `.keys/signing-config.json`:
```bash
cosign signing-config create \
  --no-default-rekor --no-default-fulcio --no-default-oidc --no-default-tsa \
  --out .keys/signing-config.json
```

All `cosign sign` invocations include `--signing-config .keys/signing-config.json`.
Do not use the deprecated `--tlog-upload=false` flag.
The empty configuration file keeps signing operations offline and key-based.
The test suite `dashboard-supplychain.bats` validates these arguments.

**Verify Signatures Offline**:
```bash
cosign verify --key .keys/cosign.pub --insecure-ignore-tlog=true \
  --allow-insecure-registry <ref>@<digest>
```

## 8. False-Positive Diagnostic Probes

Some diagnostic checks report success when underlying components fail.
A wait that cannot succeed and a test that cannot fail are both defects.
Review these observed diagnostic pitfalls:

### `nc` Exit Codes Do Not Distinguish Denial from Network Errors

`busybox nc` returns exit code 1 for blocked IPs, unreachable hosts, and stopped containers.
Only standard error output reveals the true cause:

```bash
nc -z -w 2 240.0.0.1 9999     # exit 1: NetworkPolicy blocked connection
nc -z -w 2 nope.invalid 9999  # exit 1: DNS lookup failed
```

Capture standard error to classify results.
`scripts/agent-trust-local.sh` marks unclassified network failures as `UNVERIFIED`.

### New Pods Remain Unconfined During Initialization

The CNI plugin applies NetworkPolicy rules after container startup.
Tests executed at container launch measure initialization delay rather than policy enforcement.

Validate connectivity with a positive control before testing policy denial.
Confirm that permitted paths function before asserting that denied paths fail.
Report timeouts as `UNVERIFIED`. Do not report timeouts as successful denials.

### NetworkPolicies Match Labels, Not Identity

Network policies evaluate pod labels instead of ServiceAccounts or SPIFFE IDs.
If a pod lacks required labels, the network drops traffic and returns HTTP 504.
When creating probe pods, assign component label `app.kubernetes.io/component: probe`.
Exclude probe pods when querying application workloads.

### RoleBindings Target Non-Existent ServiceAccounts Silently

Kubernetes allows RoleBindings that reference non-existent ServiceAccounts.
When this occurs, API operations fail authorization silently.
The Kubernetes Go client returns empty list responses instead of permission errors.
Always verify that the target ServiceAccount exists in the specified namespace.

### Missing Reverse Proxy Locations Return `index.html` with 200 OK

When an API route lacks an nginx proxy rule, nginx returns `index.html` with status 200 OK.
Client code parses the HTML body as JSON and throws syntax errors.
Run `bats d2-signalloom/test/dashboard-route-collisions.bats` to check for proxy collisions.

### Unmatched `kubectl jsonpath` Queries Exit With Status 0

Queries with unmatched array elements print index errors to standard output and exit 0.
Always verify that target Kubernetes resources exist before parsing specific array elements.

### Read Probe Output from Termination Logs

Probe CronJobs configure `terminationMessagePolicy: File`.
Standard container logs remain empty after execution.
Inspect the termination message directly:

```bash
kubectl -n agent-trust-acme-payments get pod <probe-pod> \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.message}'
```

## Recommendations for `make doctor` (`scripts/cluster-debug.sh`)

`make doctor` checks unhealthy pods, Flux reconciliations, image pulls, and cluster events.
Include these high-value diagnostic checks:

1. **ZOT Cache Permission Check**: When the ZOT pod fails, check logs for `permission denied`.
   Print recovery instructions:
   `make zot-cache-reset && kubectl -n registry delete pod -l app=zot`.
   Verify host permissions on `.cache/zot` match `65532:750`.
2. **Missing ResourceSet Detection**: Check for `kustomize build failed` in Flux status messages.
   Print actionable path errors and notify when downstream ResourceSets are absent.
3. **Pull-Through Mirror Status**: Report the operational status of `registry-cache-*` containers.
   Verify that containerd configuration files in `certs.d/*/hosts.toml` are not empty.
4. **Wait Latency Ranking**: Read `WAIT_STAT_FILE` to report the five slowest wait operations.
   Identify tight timeout thresholds systematically.
5. **Actionable Remediation**: Keep `make doctor` read-only.
   Provide exact recovery commands for every detected failure.
