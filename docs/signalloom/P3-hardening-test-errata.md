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
## Negative proof log selection correction

<!-- machine-tag: SIGNALLOOM-P3-IDENTITY-LOG-SELECTION-2026-07-26T16:56:00+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- commit: 738c5cd97c1970ce94491aad9550c8a82cdd3ba3 -->
<!-- scope: static-runtime-verifier-and-fixture-harness-only -->

The bounded positive and negative identity proof Jobs remain distinct: the
authorised `fe-signalloom` Job must complete after its Bao read, while the
unauthorised `fe-signalloom-negative` Job must fail after its SPIRE identity
request is denied. The negative denial marker is intentionally emitted by the
failing `jwt-svid` init container. The runtime verifier now explicitly selects
that container when collecting the negative Job log; unqualified Job logs can
select the regular `proof` container, which does not start after init failure.

The local deterministic harness now fails if that explicit container selector
is removed. `make test-bao-spire-proof-harness` passed 5/5, `make -C
d2-signalloom bao-test-config`, `make -C d2-signalloom test` passed 17/17,
`make signalloom-check`, `bash -n scripts/bao-spire-proof.sh`, and `git diff
--check` passed for this correction.

This is qualified static and fake-boundary evidence only. It does not claim a
live Kind reconciliation, a live SPIRE identity denial, a live OpenBao read,
Flux application readiness, or any Gate C/D/E runtime result. No board state
was edited and no remote push was performed.
## OSRAMP backend configuration validation errata

<!-- machine-tag: OSRAMP-BACKEND-VALIDATION-2026-07-26T17:00:47+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- scope: repository-local-source-test-and-disposable-container-only -->

This bounded record validates the checked-in OSRAMP PostgreSQL, Redis, and
MinIO configuration plus the Discovery Portal bootstrap drift contract. It
does not modify `board.json`, an Obsidian proposal, a Kubernetes cluster, or
any external system; no push is authorised or claimed.

`make -C d2-osramp-apps test-config` passed its five deterministic checks:
backend rendering, PostgreSQL archive-bootstrap declarations, Redis source and
explicit drift policy, MinIO console binding, and restart-safe bucket setup.
The base and staging backend manifests rendered through `kubectl kustomize`.

A disposable `postgres:18` container executed the extracted ConfigMap bootstrap
on a fresh data directory. It established superuser roles `archiver` and
`postgres`, created `task_archive`, and returned `true` for the configured
application user's `CREATE` privilege. Image `PGDATA` was
`/var/lib/postgresql/18/docker`, matching the checked-in Pod mount.

The pre-correction MinIO bucket command failed on its second invocation because
`attestations` already existed. The committed command now uses
`mc mb --ignore-existing local/attestations`; a disposable MinIO runtime passed
both first and repeated bucket setup while its process arguments contained
`--console-address :9001`.

Redis remains deliberately excluded from the backend base Kustomization, and
its HelmRelease declares `driftDetection.mode: disabled`. The validation proves
those source facts and the pinned OCI chart reference only; it does not claim a
deployed Redis release or active Redis drift remediation.

Bootstrap validation passed `make -C d2-signalloom bootstrap-drift`,
`bats test/bootstrap.bats` (2/2), and `make -C d2-signalloom test` (17/17).
An isolated copied checkout whose committed bootstrap contract was deliberately
altered made `check-bootstrap-drift.sh` fail, proving the checker rejects that
drift fixture. These are deterministic source and disposable-container results,
not live cluster readiness, Flux reconciliation, external object-storage, or
production acceptance evidence.

## Phase 2 Governor integration outcome

<!-- machine-tag: SIGNALLOOM-PHASE2-GOVERNOR-INTEGRATION-BLOCKED-2026-07-26T17:33:00+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- integration-sha: 093c07d -->
<!-- status: blocked validation=failed owner=phase2-governor -->
<!-- scope: repository-local-merge-and-static-validation-only -->

The Governor merged the signed, verified implementation commits
`b23a817dde143326ecf40ea240d8c22adae5dc4d`,
`1453fd77c87d6a9ad5944a64d8c700ca3240e0af`, and
`9c511c137568c72ac71b76344cc01a6457ac16f7` into this dedicated local
integration branch. The resulting merge commits are `e5ce462`, `da16b0f`, and
`093c07d`; conflict resolution retained each independent evidence record.

Post-merge `make demo-signalloom-test-config`, `make test-demo-lifecycle`,
`bats test/signalloom-flux-integration.bats`, and `git diff --check` passed.
`make signalloom-check` is blocked because its delivery-contract guard requires
`main` to be an ancestor of `integration/signalloom-d2-v2.0.0`; the condition
was already false at pre-merge commit `6901c5576983a28f96c471b7563221e56706bc67`.
This outcome does not claim a complete phase pass, runtime Gate C/D/E result,
board-state edit, or remote push.

## Phase 6 recovery qualified failure

<!-- machine-tag: SIGNALLOOM-PHASE6-RECOVERY-FAIL-2026-07-26T19:28:03+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- integration-sha: 879291f090ef4fc57c438335ae15f5c967928425 -->
<!-- task-sha: eac7e5c30071b1255c430e523462e09f97b9b93b -->
<!-- status: blocked validation=failed owner=phase6-recovery -->
<!-- blocker: spire-agent-lacks-get-nodes-proxy-rbac -->
<!-- unsigned-commit-exception: principal-authorized-yubikey-unavailable -->
<!-- scope: single-kind-osramp-local-signalloom-only -->

The recovery task was committed locally and rebased onto the current local
integration tip. The retained unsigned task commits implement direct,
image-resident Bao/SPIRE proof commands, focused helper tests, numeric portal
identity configuration, and portal database-pool startup. The final task SHA is
`eac7e5c30071b1255c430e523462e09f97b9b93b`; no push, merge into integration,
or Kanban board edit was performed. Unsigned commits were explicitly authorised
while the principal's YubiKey was unavailable.

### Passing evidence

- `kind get clusters` was inspected before recreation, the existing `osramp`
  cluster was deleted, the inventory was confirmed empty, and the canonical
  `CLUSTER_NAME=osramp make demo-signalloom-up` lifecycle recreated only
  `osramp`.
- `make -C d2-signalloom test` passed 20/20, including direct helper command,
  shell-dependency rejection, numeric `runAsUser`, and preserved identity
  boundary checks. `make test-bao-spire-proof-harness` passed 5/5 and
  `make test-demo-signalloom-lifecycle` passed 4/4.
- The helper image built successfully. Its Go tests cover exact JWT extraction,
  malformed and ambiguous responses, retry behaviour, file mode `0600`, and
  fail-closed negative identity handling.
- The portal's containerised Python suite passed 11/11. Live
  `deployment/fe-signalloom` is `1/1 Available`; its replacement pod is `1/1
  Running` and no longer reports `CreateContainerConfigError`.
- `make demo-signalloom-test` passed. Both Signalloom ResourceSets and all five
  tenant Kustomizations report `Ready=True`.
- Exactly five expected Flux deployments exist in `flux-system`: one operator
  plus source, kustomize, helm, and notification controllers. No second Flux
  control plane was created.
- The negative proof Job reaches `Failed` and its `jwt-svid` init container logs
  `denied as expected`, preserving the intended unauthorised boundary.

### Blocking runtime evidence

The positive proof Job reaches `Failed`, not `Complete`. Its direct helper
executable starts successfully, then receives `PermissionDenied: no identity
issued`. SPIRE's Kubernetes workload attestor first demonstrated that the
node-local kubelet was unreachable from the existing agent network namespace.
A bounded diagnostic using node networking and local certificate-verification
bypass then reached the kubelet and exposed the decisive existing-RBAC failure:

```text
403 Forbidden (user=system:serviceaccount:inf-bao:default,
verb=get, resource=nodes, subresource(s)=[pods proxy])
```

`kubectl auth can-i get nodes/proxy
--as=system:serviceaccount:inf-bao:default` returns `no`. Per the principal's
safety boundary, no ClusterRole, ClusterRoleBinding, broader permission, or
lasting security-posture change was introduced. The diagnostic host-networking
and kubelet-verification changes were reverted in source and in the live
`inf-bao` slice before this record was written.

### Minimum-privilege escalation requiring principal approval

The narrow Kubernetes-native correction would create a dedicated
`inf-bao/spire-agent` ServiceAccount, grant only `get` on the `nodes/proxy`
subresource through a dedicated ClusterRole, and bind that role only to the new
ServiceAccount. The DaemonSet would use that identity plus an explicitly trusted
Kind kubelet CA and node-local network path. Acceptance must prove the positive
Job completes, the negative Job remains denied, `kubectl auth can-i` grants only
the required verb/resource, and no unrelated ServiceAccount gains access.

Alternatives are to expose and use a read-only kubelet endpoint in the disposable
Kind configuration, or replace Kubernetes workload attestation with a different
selector model. Both alter a larger trust boundary and are not recommended over
the dedicated minimum-privilege identity. Principal approval is required before
any option is implemented.

`make signalloom-check` remains independently blocked by the pre-existing
integration contract condition that `main` is not an ancestor of
`integration/signalloom-d2-v2.0.0`. This record therefore claims a qualified
Phase 6 failure, not a release, Gate C/D/E pass, or complete Bao/SPIRE runtime
proof.

## SLD21 P6 Governor qualified completion

<!-- machine-completion-tag: SLD21-P6-GOV -->
<!-- machine-tag: SLD21-P6-GOV-QUALIFIED-2026-07-26T21:04:00+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- integration-sha: 14f1846e333774e6780f64a923f6978c8652b1b0 -->
<!-- recovery-commits: 76e9d04647a88b1e5da5ca7f817e4bb621b4da70,60123eb23165fa0fe9c5cf7fff13ac023638d322 -->
<!-- status: qualified-complete validation=passed owner=phase6-governor -->
<!-- scope: single-kind-osramp-local-signalloom-only -->

The Governor verified that recovery commits `76e9d046` and `60123eb2` are
already ancestors of integration HEAD `14f1846e`; no redundant merge was made.
With principal-approved local recreation, `kind get clusters` returned exactly
one cluster, `osramp`. `CLUSTER_NAME=osramp make demo-signalloom-up` converged,
then `make demo-signalloom-runtime-test` passed: source validation 20/20,
focused runtime BATS 2/2, and lifecycle BATS 4/4.

This completion is qualified. It preserves the Phase 6 positive Bao/SPIRE proof
blocker recorded above: no `nodes/proxy` RBAC, ClusterRole, ClusterRoleBinding,
or other trust-boundary change was introduced. It does not claim release
approval, Gate C/D/E proof completion, delivery-contract clearance, board-state
modification, or a remote push. The machine outcome is retained locally at
`MEMORY/WORK/20260726-210400_phase6-governor-outcome.json`.
