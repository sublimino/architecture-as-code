# Testing

This repository has deterministic tests, Kubernetes-backed end-to-end tests, and browser-driven acceptance tests. This document is the canonical technical guide for running them.

For a human review of the live browser experience, use [HUMAN_VALIDATION.md](HUMAN_VALIDATION.md).

## Browser acceptance tests

The browser suite uses Playwright 1.61.1, Bun, and the system Chrome channel.

**[`test/acceptance/SPEC-REGISTRY.tsv`](test/acceptance/SPEC-REGISTRY.tsv) is the
source of truth for where each spec runs**, and CI stage 1c
([`test/acceptance-spec-coverage.bats`](test/acceptance-spec-coverage.bats))
enforces it against `playwright.config.ts`, the `Makefile` and
`scripts/ci/vm-pipeline.sh`. Read the registry, not this paragraph: this section
described "68 tests across 9 specs in four projects" long after the config had
grown to six projects and 70 tests in 12 files, which is why the registry exists
in a form that can fail a build.

In summary, as of 2026-08-13:

| Where | Specs |
| --- | --- |
| CI stage 8 | `signalloom-test-1.spec.ts` |
| CI stage 8b | `smoke.spec.ts` |
| `make demo-signalloom-supercred-two-window` | `supercred-two-window.spec.ts` |
| `make acceptance-test` only | `afm-frontend`, `afm-integration`, `credential-lifecycle`, `rbac-analysis`, `rbac-explorer`, `signalloom-login`, `supercred-evidence-lifecycle`, `supercred-ui-lifecycle` |
| Nowhere — matches no project `testMatch` | `cluster.spec.ts`, `dashboard-journey.spec.ts`, `supercred-live-pages.spec.ts`, `supercred-page.spec.ts` |

Playwright does not warn when no project claims a spec; it reports a smaller
total and exits 0. Anything below describing `cluster.spec.ts` — including the
Grafana / Archivista / Olly assertions and the baseline at the end of this
section — documents a spec the command does not execute. Wire it into a project
before relying on it.

Note that `make acceptance-test` with no arguments is no longer a quick check:
`supercred-ui-lifecycle` and `supercred-evidence-lifecycle` each carry a
30-minute project timeout. Pass a filename to run one spec.

The historical eight-test description of [`test/acceptance/cluster.spec.ts`](test/acceptance/cluster.spec.ts) follows:

| Area | Tests | Expected endpoint |
| --- | ---: | --- |
| Grafana | 2 | `http://127.0.0.1:13000` |
| Archivista API | 2 | `http://127.0.0.1:18082` |
| SignalLoom frontend | 2 | `http://127.0.0.1:18000` |
| Olly customer portal | 2 | `http://127.0.0.1:18080` |

### Prerequisites

- Docker, kind, kubectl, Bun, and Chrome are installed.
- The local cluster is running with the `kind-osramp` context selected.
- The workloads under test are deployed and healthy.
- Port `13000`, `18000`, `18080`, and `18082` are available locally.

Install the JavaScript dependencies and FFmpeg artifact once:

```bash
cd test/acceptance
bun install --frozen-lockfile
bunx playwright install ffmpeg
cd ../..
```

### Canonical command

Run from the repository root:

```bash
make acceptance-test
```

The wrapper runs the cluster doctor, creates the required Kubernetes port-forwards, runs Playwright, prints the HTML report and artifact paths on failure, and always cleans up its port-forwards. Additional Playwright arguments are passed through:

```bash
./scripts/acceptance-test.sh --grep "SignalLoom Frontend"
```

### Diagnostics and artifacts

The Playwright configuration retains diagnostics for failed tests:

- HTML report: `test/acceptance/playwright-report/index.html`
- Per-test artifacts: `test/acceptance/test-results/`
- Trace archives: `trace.zip`
- Failure screenshots for page tests: `failure-screenshot-*.png`
- Failure videos: `video.webm`
- Browser diagnostics: `browser-diagnostics-*.txt`
- Playwright error context: `error-context.md`

Inspect a trace using the command printed by the wrapper, replacing the directory placeholder:

```bash
cd test/acceptance
bunx playwright show-trace test-results/<failed-test>/trace.zip
```

Page tests capture console output, uncaught page errors, failed requests, and HTTP responses with status 400 or higher. API tests report connection and response failures directly in the Playwright call log.

### Latest observed baseline

On 2026-07-26 in the V2.5 integration worktree:

- **4 passed:** both Grafana tests and both SignalLoom frontend tests.
- **4 failed:** both Archivista tests because `backend/osramp-archivista` was unavailable, and both Olly portal tests because `olly-replica/customer-portal` was unavailable.

These are environment/service-availability failures, not an assertion change. Run the cluster doctor output at the start of the command before interpreting the browser failures.

## Shared cluster diagnostics

Use these read-only commands from the repository root to establish cluster
state before debugging a demo or an acceptance-test failure.

### Start with the repository reports

```bash
make doctor  # equivalent to: make cluster-debug
```

`make doctor` and `make cluster-debug` run the same comprehensive, read-only
diagnostic report. It shows cluster connectivity, unhealthy pods, restart
counts, recent warning events, non-ready Flux objects, node metrics, and
image-pull failures. It exits non-zero when it detects unhealthy pods.

### Inspect unready Flux resources and recent reconciliations

```bash
# Any Flux resource that is not Ready.
flux get all -A --status-selector ready=false

# Recent Flux controller activity and errors.
kubectl get events -n flux-system --sort-by='.lastTimestamp'
kubectl -n flux-system logs deployment/kustomize-controller --tail=200
kubectl -n flux-system logs deployment/source-controller --tail=200

# Inspect the status and events for one reported Kustomization.
kubectl describe kustomization <name> -n <namespace>
```

Flux does not expose a portable “currently reconciling” list. Use the resource
state command plus the controller event stream and logs above to see the latest
or in-progress reconciliation activity.

### Inspect workloads and error events

```bash
# READY and current state across workloads.
kubectl get pods -A -o wide
kubectl get deployments,statefulsets,daemonsets -A

# Warning events across every namespace, newest last.
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp'

# Logs for a failing application workload.
kubectl -n <namespace> logs deployment/<deployment> --tail=200
```

### Inspect Kubernetes API-server logs

The Kind control plane exposes the API server as a static pod. Confirm its pod
name before reading its recent logs:

```bash
kubectl -n kube-system get pods -l component=kube-apiserver
kubectl -n kube-system logs pod/kube-apiserver-osramp-control-plane --tail=200
```

Do not rely on personal shell aliases such as `kpo` or `klog`: this repository
does not provide them. Use the portable commands above in agent instructions,
runbooks, and CI investigations.

## Other test suites

- OSRAMP application suite: `make test`
- SignalLoom topology validation: `d2-signalloom/test/validate-topology.sh`
- SignalLoom topology BATS suite: `bats d2-signalloom/test/topology.bats`
- Fleet patch-index check: `bats d2-signalloom/test/fleet-patch-indexes.bats`
  (the local overlay patches ResourceSets by positional index; asserts each
  patched index still points at an `OCIRepository`; needs `yq`, no cluster)
- Acceptance-spec coverage registry: `bats test/acceptance-spec-coverage.bats`
  (every spec in `test/acceptance` must declare where it runs, and the
  declaration is cross-checked against `playwright.config.ts`, the `Makefile`
  and `scripts/ci/vm-pipeline.sh` in both directions; needs `python3`, no
  cluster — runs as CI stage 1c)
- CI build parity: `make test-ci-build-parity`, or `make check-ci-build-parity`
  to check the tree directly
  (`scripts/ci/vm-pipeline.sh` cannot call `make demo-signalloom-up`, so it
  hand-copies the recipe body; the guard derives the `$(MAKE)` steps from that
  recipe and the `make` invocations from the pipeline and fails when one is
  omitted, runs after the deploy, or is exempted by a stale entry. Deliberate
  omissions live in the script's allowlist with a reason; needs `bats`, no
  cluster — runs as CI stage 1d)
- Dashboard route-collision check: `bats d2-signalloom/test/dashboard-route-collisions.bats`
  (no nginx proxy prefix may shadow a SPA route in `App.tsx` or sit under a
  gateway path routed away from the dashboard; needs `yq`, no cluster)
- Agent-discovery RBAC drift check: `bats d2-signalloom/test/agent-discovery-rbac.bats`
  (asserts every namespace in the proxy's `AGENT_DISCOVERY_NAMESPACES` has a
  matching pod-reading grant; needs `yq`, no cluster)
- SuperCred image build/load guard: `make demo-signalloom-supercred-images-test`
  (fakes `docker`/`kind` via `DOCKER_BIN`/`KIND_BIN`; no cluster)
- SuperCred proxy unit suite: `make -C d2-signalloom/apps/fake-integration-proxy test`
- Browser acceptance suite: `make acceptance-test`
