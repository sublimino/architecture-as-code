# Human validation: browser acceptance

Use this checklist to review the live browser experience after the cluster has been deployed. It is intentionally separate from [`TESTING.md`](TESTING.md): that file explains how to run tests; this file records what a person observed.

## Reviewer record

| Field | Value |
| --- | --- |
| Reviewer |  |
| Date and time |  |
| Git commit |  |
| Kubernetes context |  |
| Cluster status |  |
| Result | ☐ Pass ☐ Pass with known environment failures ☐ Fail |

## Setup

- [ ] From the repository root, run `make acceptance-test`.
- [ ] Confirm the opening cluster-doctor output is recorded.
- [ ] Confirm the browser command finishes with an explicit pass/fail summary.
- [ ] Record the HTML report path and the test-results path.

## Browser review

### Grafana

- [ ] Open `http://127.0.0.1:13000`.
- [ ] Grafana displays its welcome/login page.
- [ ] The username field is visible.
- [ ] Browser console contains no unexpected errors.

Evidence or notes:

```text

```

### SignalLoom frontend

- [ ] Open `http://127.0.0.1:18000`.
- [ ] The frontend responds without a server error.
- [ ] The page renders non-empty content.
- [ ] Browser console contains no unexpected errors.

Evidence or notes:

```text

```

### Archivista API

- [ ] Confirm `backend/osramp-archivista` exists before marking this area passed.
- [ ] Confirm `http://127.0.0.1:18082/` responds.
- [ ] Confirm `POST http://127.0.0.1:18082/query` returns HTTP 200.
- [ ] Record the GraphQL response or the exact connection failure.

Evidence or notes:

```text

```

### Olly customer portal

- [ ] Confirm `olly-replica/customer-portal` exists before marking this area passed.
- [ ] Open `http://127.0.0.1:18080`.
- [ ] The portal responds without a server error.
- [ ] The page renders non-empty content.

Evidence or notes:

```text

```

## Failure evidence

For every failed check, record the test name, file/line, root error, and artifact path.

| Test or check | Error | Artifact path | Follow-up |
| --- | --- | --- | --- |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |

For trace-based debugging:

```bash
cd test/acceptance
bunx playwright show-trace test-results/<failed-test>/trace.zip
```

## Current known baseline

The 2026-07-26 V2.5 baseline passed Grafana and SignalLoom (four tests) and failed Archivista and Olly (four tests) because their expected services were unavailable. Do not mark those areas as human-validated until the services are present and the checks have been rerun.

## Reviewer conclusion

```text
What worked:

What failed:

What should be fixed before sign-off:

```
