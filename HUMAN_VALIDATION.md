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

### Local Witness evidence

- [ ] Run `make promotion-demo`.
- [ ] Confirm the original generic artifact passes the signed policy.
- [ ] Confirm the modified generic artifact fails the signed policy.
- [ ] Retain `docs/records/ci-evidence/local-witness/` with the CI run or validation record.
- [ ] Compare both public-key fingerprints with an independently held value.

The bundle contains public keys, signed policies, DSSE envelopes, artifacts,
and rejection diagnostics. It must not contain a private key. The fingerprint
file is not an independent trust root. Obtain the expected fingerprints through
a separately controlled channel before you approve the evidence.

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
not the current state. Its service-availability results do not describe the
current local-evidence contract.

## Reviewer conclusion

```text
What worked:

What failed:

What should be fixed before sign-off:

```
