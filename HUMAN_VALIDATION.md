# Human validation: browser acceptance

Use this checklist to review the live browser experience after you deploy the
cluster. [`TESTING.md`](TESTING.md) tells you how to run the tests. This file
records what a person saw.

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
- [ ] Confirm the browser command finishes with an explicit pass or fail summary.
- [ ] Record the HTML report path and the test-results path.

## Browser review

NOTE: `make acceptance-test` does not run the checks in this section. The
matching spec, `cluster.spec.ts`, is marked `unwired` in
[`test/acceptance/SPEC-REGISTRY.tsv`](test/acceptance/SPEC-REGISTRY.tsv). Check
each URL by hand.

### Signal Loom dashboard

`make acceptance-test` forwards the gateway to port `30754`. The host name has
no DNS record. Add `127.0.0.1 dashboard.osramp.acme.local` to `/etc/hosts`
before you open it. The routes are in
[`App.tsx`](d2-signalloom/apps/dashboard-signalloom/src/App.tsx).

- [ ] Open `https://dashboard.osramp.acme.local:30754` and log in.
- [ ] The Agents page (`/agents`) lists agents.
- [ ] The Compliance page (`/compliance`) renders its frameworks.
- [ ] The Audit page (`/audit`) renders the audit trail.
- [ ] The Settings page (`/settings`) renders.
- [ ] Browser console contains no unexpected errors.

Evidence or notes:

```text

```

### Grafana

Before this check, start the cluster with `ENABLE_OBSERVABILITY=true make up`.

- [ ] Open `http://127.0.0.1:13000`.
- [ ] Grafana displays its welcome or login page.
- [ ] The username field is visible.
- [ ] Browser console contains no unexpected errors.

Evidence or notes:

```text

```

### Signal Loom API

Port `18000` is the forward of the `fe-signalloom` API service.

- [ ] Open `http://127.0.0.1:18000`.
- [ ] The API root responds without a server error.
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

- [ ] Confirm that `customer-portal` is defined in [`olly-replica/components/configs/base/tenant-apps.yaml`](olly-replica/components/configs/base/tenant-apps.yaml) before you mark this area passed.
- [ ] Open `http://127.0.0.1:18080`.
- [ ] The portal responds without a server error.
- [ ] The page renders non-empty content.

Evidence or notes:

```text

```

## Failure evidence

For every failed check, record the test name, file and line, root error, and artifact path.

| Test or check | Error | Artifact path | Follow-up |
| --- | --- | --- | --- |
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |

The trace command is in
[`TESTING.md`](TESTING.md#diagnostics-and-artifacts).

## Baseline history

NOTE: The 2026-07-26 V2.5 baseline predates the current suite. It is history,
not the current state. It passed Grafana and Signal Loom (four tests). It failed
Archivista and Olly (four tests) because those services were absent.

## Reviewer conclusion

```text
What worked:

What failed:

What should be fixed before sign-off:

```
