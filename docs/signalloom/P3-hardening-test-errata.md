# Phase 3 hardening test errata

<!-- machine-tag: SIGNALLOOM-P3-HARDENING-TESTS-2026-07-26T06:30:00+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- scope: local-fixture-and-harness-only -->

This repository-local errata records the test translation for the Phase 3
bounded Bao/SPIRE identity design. It does not modify `board.json`, the
Obsidian proposal (`docs/plans/d2-bao-integration.md`), another worktree, a
Kind cluster, or any external system.

| Trace ID | Contract | Harness assertion | Intended regression outcome |
| --- | --- | --- | --- |
| `P3-IDENTITY-ACCEPT-001` | Authorised job completes and logs its success marker. | Fake `kubectl` returns Complete and `bounded Bao/SPIRE proof passed`. | Pass. |
| `P3-IDENTITY-NEG-001` | Unauthorised service account must not complete. | Fake negative job reports Complete. | Fail: `negative Bao/SPIRE identity unexpectedly succeeded`. |
| `P3-IDENTITY-NEG-002` | Unauthorised job must enter Failed. | Fake negative job never reaches Failed. | Fail. |
| `P3-IDENTITY-EVIDENCE-001` | Positive completion needs a proof marker. | Fake positive logs omit its marker. | Fail: missing positive marker. |
| `P3-IDENTITY-EVIDENCE-002` | Negative failure needs a denial marker. | Fake negative logs omit its marker. | Fail: missing denial marker. |

Run the deterministic evidence suite with:

```sh
env LC_ALL=C LANG=C make test-bao-spire-proof-harness
```

The suite deliberately replaces only `kubectl` through a temporary `PATH`; it
does not create, reconcile, delete, or query a real cluster. Consequently it
qualifies the control-flow assertions only. Real Kind acceptance remains
blocked until the existing Bao/Flux readiness blockers are repaired; it must
then be run separately against a disposable local cluster.

## Local evidence

<!-- machine-tag: SIGNALLOOM-P3-HARDENING-EVIDENCE-2026-07-26T06:31:00+01:00 -->

The following commands ran from the Kanban runtime worktree and exited zero:

```text
env LC_ALL=C LANG=C make test-bao-spire-proof-harness
# 1..5: expected acceptance plus four deliberately violated outcomes detected
env LC_ALL=C LANG=C make -C d2-signalloom bao-test-config
env LC_ALL=C LANG=C make -C d2-signalloom test
# 1..9 existing deterministic static assertions
bash -n scripts/bao-spire-proof.sh
```

`test/bao-spire-proof.bats` is the durable fixture artifact: every negative
case changes exactly one fake-kubectl outcome, asserts non-zero exit status,
and, where the production script emits a diagnostic, asserts that diagnostic.
No runtime readiness, network-policy enforcement, or application request is
claimed by this local harness.

## Governor partial-integration pass errata

<!-- machine-tag: SIGNALLOOM-P3-PARTIAL-INTEGRATION-PASS-2026-07-26T08:03:00+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- scope: committed-input-recovery-and-static-tests-only -->

The Governor recovered and verified four signed, committed Phase 3 inputs in
the dedicated Governor worktree. P3-1 is `dbe6d31c78a2ed23ddcde88e6b7cc5b2310b7dad`,
P3-2 is `5cc782c94853e85dda2b1ac144536f07861a6904`, P3-3 is
`586668fadf038553624aa135b05ddbd53225ff27` (located through the
`refs/kanban/checkpoints/Yjc5N2M/turn/2` task:b797c evidence ref), and P3-4 is
`bf78420f451cac83cfe73a71844191032c2cc49e`. All four signatures verified
against the repository's trusted signing key.

Each input was merged with `--no-ff` into
`integration/signalloom-d2-v2.0.0`. The P3-3 merge required conflict
resolution only to retain both independent documentation errata sections;
its implementation and test changes were accepted unchanged.

Strict repository validation passed after integration:

- `make signalloom-check`
- `make demo-signalloom-test-config` (12/12)
- `make test-demo-lifecycle` (4/4)
- `bats test/signalloom-flux-integration.bats` (3/3)
- `make test-zot-cache` (3/3)
- `make test-bao-spire-proof-harness` (5/5)
- `make -C d2-signalloom bao-test-config`
- `make -C d2-signalloom test` (12/12)
- `bash -n scripts/bao-spire-proof.sh`
- `git diff --check`

This is a partial integration pass only. It does not approve Phase 3, does
not claim P3-5 runtime proof, and does not convert static or fake-boundary
results into live Kind, Bao/SPIRE, Flux, portal, or hosted evidence. P3-5
must be recreated from the resulting clean integration HEAD.

## Governor verification rerun

<!-- machine-tag: SIGNALLOOM-P3-PARTIAL-INTEGRATION-STRICT-RERUN-2026-07-26T08:29:41+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- integration-sha: e21a9e559107e0f335651e69d2be598c245c08eb -->
<!-- scope: verification-rerun-only -->

The dedicated Governor worktree was clean at `e21a9e559107e0f335651e69d2be598c245c08eb`.
The four qualified inputs remained reachable, signed by the trusted repository
key, and present through the existing no-ff merge commits. Strict validation was
rerun successfully: `make signalloom-check`, `make demo-signalloom-test-config`
(12/12), `make test-demo-lifecycle` (4/4), `bats
test/signalloom-flux-integration.bats` (3/3), `make test-zot-cache` (3/3),
`make test-bao-spire-proof-harness` (5/5), `make -C d2-signalloom
bao-test-config`, `make -C d2-signalloom test` (12/12), `bash -n
scripts/bao-spire-proof.sh`, and `git diff --check`.

This remains a partial integration verification only. It does not approve Phase
3 or claim P3-5 runtime proof; P3-5 must be recreated from this clean
integration SHA.

## Phase 2 Gate C/D/E runtime recovery handoff

<!-- machine-tag: SIGNALLOOM-PHASE2-RUNTIME-HANDOFF-2026-07-26T13:25:12+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- integration-sha: e1c969c -->
<!-- scope: local-kind-zot-flux-only status=deferred owner=phase2-governor -->

Principal-directed handoff: this record is limited to reversible local/demo
runtime recovery. It neither changes `board.json` or the Obsidian proposal nor
authorises hosted, hardening, production, Phase 3+, external infrastructure,
credentials, or a release. The bounded source/test recovery is committed as
`e1c969c` and is deliberately handed to the dedicated Phase 2 Governor for
timeboxed integration validation. No push was performed.

### Demonstrated local evidence

- The initial Kind runtime diagnostic recovered the exact OpenBao failure from
  the node container runtime: `su-exec: setgroups: Operation not permitted`.
  The OpenBao Deployment now invokes `/bin/bao` directly as the image's
  non-root UID/GID while retaining `allowPrivilegeEscalation: false` and dropped
  capabilities; a constrained local image experiment started successfully,
  whereas the stock entrypoint failed with the recorded `setgroups` error.
- Flux reconciled the repaired Bao controller and config slices from signed
  local Zot OCI artifacts. The local lifecycle generated an ephemeral SPIRE
  join token and registered the bounded positive workload identity. The final
  successful `demo-bao-up` output is in retained evidence.
- The Signalloom dependency slice reconciled using direct disposable local
  PostgreSQL, Redis, and MinIO workloads rather than relaxing the tenant OCI
  source allowlist. Its bootstrap ConfigMap was moved into the controller slice
  to avoid the controller/config dependency deadlock.
- Static verification passed after the recovery: `make signalloom-check`,
  `make demo-signalloom-test-config` (16/16), `bats
  test/bao-spire-proof.bats test/demo-lifecycle.bats
  test/signalloom-flux-integration.bats` (13/13), shell syntax checks, and
  `git diff --check`.

### Deferred runtime gap and current state

The final `make demo-signalloom-up` remained non-green. Flux reports
`fe-signalloom/apps` `Ready=False`; its retained API diagnostic records a
reconciliation failure attempting to update the existing negative proof Job's
immutable pod template after the local SPIRE helper change. Earlier attempts
also recorded the original distroless SPIRE image lacking `sh` and the portal
init container image/root-security-context mismatch. The repair source includes
the bounded helper and lifecycle scaffolding, but **no live positive/negative
identity proof, portal readiness proof, lifecycle idempotency proof, teardown
safety proof, or Gate C/D/E pass is claimed**. The incoming Governor must start
from the current committed source with a clean, timeboxed local Kind/Zot/Flux
validation plan, delete/recreate only disposable demo Jobs as appropriate, and
re-run those proofs with fresh diagnostics.

### Retained exact evidence

All command transcripts and diagnostics are retained locally at
`/tmp/opencode/signalloom-d2-v2.0.0-20260726T1105+0100/`. Key transcripts are:

- `22-helper-build-static.log` — local helper build and static failure-path
  suite;
- `24-live-agent-env-helper.log` — Bao/Flux reconciliation prior to the
  escaped Flux variable correction;
- `25-live-app-proof.log` — latest live Signalloom stack attempt;
- `26-final-static-verification.log` — final passing static verification.

The final observation-only snapshot recorded `inf-bao` and `inf-signalloom`
Flux slices reconciled, while `fe-signalloom/apps` stayed false for the
immutable negative Job update. No additional lifecycle command was run after
the principal-directed stop.

## Local proxy and demo-control validation errata

<!-- machine-tag: SIGNALLOOM-LOCAL-PROXY-CONTROL-VALIDATION-2026-07-26T16:53:34+01:00 -->
<!-- scope: deterministic-local-handler-and-container-tests-only -->

This repository-local validation adds deterministic coverage for the desktop
console proxy and the fake integration-proxy demo controls. It does not modify
`board.json`, the Obsidian proposal, another worktree, a Kind cluster, hosted
services, or any external system. No push was performed.

### Established behaviour

- `/proxy/adk/` selects the host-local ADK target at
  `127.0.0.1:${ADK_PORT:-8000}`. Its new handler test uses an ephemeral local
  HTTP backend and proves subpath rewriting, query preservation, successful
  response propagation, and removal of upstream framing headers.
- `/proxy/grafana/` is allowlisted to the supervised port-forward target
  `olly-replica/eye-in-the-sky-grafana:80`; the target mapping is covered as a
  deterministic source-level assertion. It was not contacted.
- Unrecognised `/proxy/<name>/...` names return the console's JSON `503`
  unavailable response rather than selecting an arbitrary target. The handler
  itself deliberately has no authentication or origin check; its current
  access boundary is the default local console binding. Changing that posture
  was outside this validation scope.
- `DELETE /_test/requests` clears only in-memory captured request history. It
  does not revert fixture overrides, rebuild a container, reconcile a cluster,
  or reset any lifecycle state. `GET /_test/requests` observes the capture
  history, while `PUT /_test/fixtures/<category>/<name>` changes a demo fixture.
- Demo controls return `404` outside `SIGNALLOOM_DEMO_PROFILE=demo`. Captured
  structured secret-shaped fields are replaced with `[REDACTED]`, sensitive
  headers are excluded from capture, and non-JSON bodies become
  `[REDACTED_NON_JSON_BODY]`.

### Local evidence

The following commands exited zero in this worktree:

```text
go test ./...                                  # tools/demo-console (3 tests)
make -C d2-signalloom/apps/fake-integration-proxy test
# 6 in-process deterministic handler tests
make -C d2-signalloom/apps/fake-integration-proxy container-test
# Docker build plus isolated container smoke test
git diff --check
```

This evidence does **not** establish a running ADK service, Grafana login or
embedding success, a `kubectl port-forward`, browser behaviour, network-policy
enforcement, production authentication, persistence across proxy restarts, or
live Kind acceptance. The Grafana route's target is source-tested only; an
operational path test needs a disposable local cluster and should be reported
separately. This erratum records the boundary rather than converting local
fixtures into runtime proof.
