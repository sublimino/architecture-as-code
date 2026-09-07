# Testing

This repository contains deterministic tests, Kubernetes end-to-end tests, and
Playwright browser acceptance tests. This document provides instructions to run them.

For manual browser testing, read [HUMAN_VALIDATION.md](HUMAN_VALIDATION.md).

## Browser Acceptance Tests

The browser test suite uses Playwright, Bun, and Google Chrome.

The file [`test/acceptance/SPEC-REGISTRY.tsv`](test/acceptance/SPEC-REGISTRY.tsv)
is the single source of truth for test locations. The CI check
[`test/acceptance-spec-coverage.bats`](test/acceptance-spec-coverage.bats) verifies
the registry against `playwright.config.ts`, the `Makefile`, and `scripts/ci/vm-pipeline.sh`.

Current spec assignments (from `SPEC-REGISTRY.tsv`):

| Location | Specs |
| --- | --- |
| CI stage 8 | `signalloom-test-1.spec.ts` |
| CI stage 8b | `smoke.spec.ts`, `live-data.spec.ts` |
| `make demo-signalloom-supercred-two-window` | `supercred-two-window.spec.ts` |
| `make demo-signalloom-supercred-stream` | `supercred-log-streaming.spec.ts` |
| `make demo-signalloom-supercred-stream-harness` | `supercred-log-streaming-harness.spec.ts` |
| `make acceptance-test` only | `afm-frontend`, `afm-integration`, `credential-lifecycle`, `rbac-analysis`, `rbac-explorer`, `signalloom-login`, `supercred-evidence-lifecycle`, `supercred-ui-lifecycle` |
| Unwired (matches no project) | `cluster.spec.ts`, `dashboard-journey.spec.ts`, `supercred-live-pages.spec.ts`, `supercred-page.spec.ts` |

Playwright gives no warning when no project claims a spec. It reports a lower total and exits 0.
Always link new specs to a Playwright project.

Note: `make acceptance-test` without arguments runs all suites. The tests
`supercred-ui-lifecycle` and `supercred-evidence-lifecycle` have 30-minute timeouts.
Pass a spec name to run a single file.

### Prerequisites

- Install Docker, Kind, kubectl, Bun, and Google Chrome.
- Select the `kind-osramp` context on your local cluster.
- Deploy target workloads and check their health.
- Make sure ports `13000`, `18000`, `18080`, and `18082` are free.

Install acceptance test dependencies:

```bash
cd test/acceptance
bun install --frozen-lockfile
bunx playwright install ffmpeg
cd ../..
```

### Canonical Commands

Run the full acceptance suite from repository root:

```bash
make acceptance-test
```

The script runs cluster diagnostics, starts port-forwards, runs Playwright,
and cleans up port-forwards on exit.

To filter tests, pass arguments to the script:

```bash
./scripts/acceptance-test.sh --grep "SignalLoom Frontend"
```

### Diagnostics and Artifacts

Playwright stores diagnostic artifacts for failed runs:

- HTML report: `test/acceptance/playwright-report/index.html`
- Test artifacts: `test/acceptance/test-results/`
- Traces: `trace.zip`
- Failure screenshots: `failure-screenshot-*.png`
- Failure videos: `video.webm`
- Browser logs: `browser-diagnostics-*.txt`

To view a trace archive:

```bash
cd test/acceptance
bunx playwright show-trace test-results/<failed-test>/trace.zip
```

### Historical Baseline

On 2026-07-26 in the V2.5 integration worktree:
- **4 passed:** Grafana tests and SignalLoom frontend tests.
- **4 failed:** Archivista and Olly portal tests because services were not deployed.

Check cluster health before you debug browser test failures.

## Shared Cluster Diagnostics

Run these read-only commands before you debug demo or test failures:

```bash
make doctor  # Same as: make cluster-debug
```
```

`make doctor` and `make cluster-debug` run the same comprehensive, read-only
diagnostic report. It shows cluster connectivity, unhealthy pods, restart
counts, recent warning events, non-ready Flux objects, node metrics, and
image-pull failures. It exits non-zero when it detects unhealthy pods.

### Inspect unready Flux resources and recent reconciliations

### Inspect Unready Flux Resources and Reconciliations

```bash
# List any Flux resource that is not Ready
flux get all -A --status-selector ready=false

# Inspect Flux controller activity and recent errors
kubectl get events -n flux-system --sort-by='.lastTimestamp'
kubectl -n flux-system logs deployment/kustomize-controller --tail=200
kubectl -n flux-system logs deployment/source-controller --tail=200

# Inspect status and events for a specific Kustomization
kubectl describe kustomization <name> -n <namespace>
```

### Inspect Workloads and Error Events

```bash
# Check pod status across all namespaces
kubectl get pods -A -o wide
kubectl get deployments,statefulsets,daemonsets -A

# View warning events across all namespaces
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp'

# View logs for a failing workload
kubectl -n <namespace> logs deployment/<deployment> --tail=200
```

### Inspect Kubernetes API Server Logs

Kind runs the API server as a static pod. Check its pod name and view logs:

```bash
kubectl -n kube-system get pods -l component=kube-apiserver
kubectl -n kube-system logs pod/kube-apiserver-osramp-control-plane --tail=200
```

## Check Deployed Code vs Source Code

Tests verify the local source tree. They do not prove what runs in the cluster.
Use the staleness check to detect drift:

```bash
make check-deployed-staleness                          # Check all instrumented workloads
./scripts/check-deployed-staleness.sh supercred-demo-runner   # Check a single workload
```

Exit codes:

| Exit Code | Meaning | Description |
|---|---|---|
| `0` | **Verified Fresh** | The workload was reached and its build fingerprint matches the working tree. |
| `1` | **Drift Detected** | The running container does not match the working tree, or is not deployed. |
| `2` | **Cannot Verify** | The check could not connect to the cluster or read the container filesystem. |

Treat exit code 2 as unverified. The check compares content fingerprints baked in
at build time, not mutable git tags or SHA strings.

Run the test suite for the staleness checker without a cluster:

```bash
make test-deployed-staleness
```

## Other Test Suites

Run these targeted test suites from the repository root:

- **Deployed staleness guard:** `make test-deployed-staleness` (checks failure paths with mock kubectl; no cluster needed).
- **Audit anchor unit suite:** `make audit-anchor-test` (checks canonical serialization and envelopes; no cluster needed).
- **Audit anchor tamper proof:** `make audit-anchor-tamper-demo` (writes real rows, anchors them, and tests tamper detection; requires cluster).
- **Audit anchor key-path guard:** `bats test/audit-anchor-keys-path.bats` (checks path handling; no cluster needed).
- **FX artifact currency:** `make fx` (checks generated copies for freshness; no cluster needed).
- **OSRAMP application suite:** `make test` (runs end-to-end application tests; requires cluster).
- **SignalLoom topology validation:** `d2-signalloom/test/validate-topology.sh` (validates topology config).
- **SignalLoom topology BATS suite:** `bats d2-signalloom/test/topology.bats` (checks topology edge rules).
- **Fleet patch-index check:** `bats d2-signalloom/test/fleet-patch-indexes.bats` (checks ResourceSet patch indexing).
- **Acceptance spec coverage registry:** `bats test/acceptance-spec-coverage.bats` (checks test registry alignment).
- **CI build parity:** `make test-ci-build-parity` (checks parity between Makefile and CI runner recipes).
- **Dashboard route-collision check:** `bats d2-signalloom/test/dashboard-route-collisions.bats` (checks SPA route collisions).
- **Agent discovery RBAC drift check:** `bats d2-signalloom/test/agent-discovery-rbac.bats` (checks pod read grants).
- **SuperCred image build guard:** `make demo-signalloom-supercred-images-test` (mocks docker/kind; no cluster needed).
- **SuperCred proxy unit suite:** `make -C d2-signalloom/apps/fake-integration-proxy test`.
