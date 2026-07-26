# Testing

This repository has deterministic tests, Kubernetes-backed end-to-end tests, and browser-driven acceptance tests. This document is the canonical technical guide for running them.

For a human review of the live browser experience, use [HUMAN_VALIDATION.md](HUMAN_VALIDATION.md).

## Browser acceptance tests

The browser suite uses Playwright 1.61.1, Bun, and the system Chrome channel. The suite currently contains eight tests in [`test/acceptance/cluster.spec.ts`](test/acceptance/cluster.spec.ts):

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

## Other test suites

- OSRAMP application suite: `make test`
- SignalLoom topology validation: `d2-signalloom/test/validate-topology.sh`
- SignalLoom topology BATS suite: `bats d2-signalloom/test/topology.bats`
- Browser acceptance suite: `make acceptance-test`
