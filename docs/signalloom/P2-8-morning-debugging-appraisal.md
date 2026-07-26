# P2-8 morning debugging/status appraisal

<!-- machine-tag: signalloom-p2-8-appraisal -->
<!-- appraisal-state: complete-with-runtime-blockers -->
<!-- generated-at: 2026-07-26T00:38:32+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- baseline-sha: d08e00f8b7f28dde061330e036c9cc2e15f354d3 -->

This is the repository-local errata appraisal for P2-8.  It deliberately does
not modify the Obsidian proposal (`docs/plans/d2-bao-integration.md`),
`board.json`, another worktree, or any external environment.

## Qualified preflight evidence

| Machine tag | Status | Exact command | Result | Durable evidence/artifact |
| --- | --- | --- | --- | --- |
| `P2-8-CONTRACT-001` | PASS | `env LC_ALL=C LANG=C make signalloom-check` | Delivery contract, deployment guard, four git roots, and six required paths passed. | `docs/signalloom/delivery-contract.json`; `scripts/signalloom-contract-check.sh`; `scripts/signalloom-preflight.sh` |
| `P2-8-CONFIG-001` | PASS | `env LC_ALL=C LANG=C make demo-signalloom-test-config` | Static topology/dependency checks and 9 Bats assertions passed. | `d2-signalloom/test/validate-topology.sh`; `d2-signalloom/test/validate-dependencies.sh`; `d2-signalloom/test/{bootstrap,portal-package}.bats` |
| `P2-8-LIFECYCLE-001` | PASS | `env LC_ALL=C LANG=C make test-demo-lifecycle` | 4/4: aliases exist; purge blocks retained consumers and unavailable consumer queries; force is explicit. | `test/demo-lifecycle.bats`; `scripts/demo-lifecycle.sh` |
| `P2-8-FLUX-HARNESS-001` | PASS | `env LC_ALL=C LANG=C bats test/signalloom-flux-integration.bats` | 3/3: local/GitHub publication/signing declarations, local Cosign verification, and Bao → infra → portal wait order. | `test/signalloom-flux-integration.bats` |

All commands above exited `0` from this worktree.  Their command output is
also retained in this P2-8 agent session's context-mode execution record.

## Runtime qualification and next action

<!-- machine-tag: P2-8-RUNTIME-QUALIFICATION -->

At `2026-07-26T00:37:44+01:00`, Docker `29.5.2`, Kind, kubectl, Flux
`v2.9.3`, Bats `1.13.0`, make, and jq were available, but `kind get clusters`
reported **no Kind clusters** and kubectl had no current context.  Therefore
no real-cluster reconciliation, application request, or teardown has yet been
claimed.  The lifecycle Bats suite is dynamic against its temporary fake
kubectl boundary; it is not equivalent to a real Kind/Flux walkthrough.

The clean integration baseline is recorded above.  This appraisal's first
commit supplies the requested committed qualified-evidence checkpoint before
any local shared-cluster mutation is considered.  Runtime work must remain
local-only, avoid teardown/purge, and capture its result in a later append.

## Robustness assessment and debugging order

1. **First:** create/qualify a disposable local Kind context, then run
   `make cluster-up registry flux-bootstrap`; preserve command output and
   inspect Flux `ResourceSet`/`Kustomization` readiness before invoking a
   Signal Loom lifecycle action.
2. **Second:** run `make flux-test`, `make demo-signalloom-up`, and
   `make demo-signalloom-test`; capture `kubectl get` and `kubectl describe`
   for the five asserted Kustomizations plus relevant Flux events on failure.
3. **Third:** run the application walkthrough only after ready reconciliation;
   retain its request/response and pod logs.  Do not run `*-down`,
   `stack-purge`, `cluster-down`, or `teardown` as P2-8 validation.
4. The current harness is strong for ordering, declaration, and fail-closed
   deletion semantics, but it does not prove OCI pull, Cosign verification,
   ResourceSet expansion, workload readiness, or a real request path.  Those
   are the highest-priority runtime gaps.

## Runtime errata append

<!-- machine-tag: P2-8-RUNTIME-ERRATA-2026-07-26T01:09:08+01:00 -->
<!-- runtime-cluster: kind-osramp -->
<!-- runtime-status: blocked-after-real-reconciliation -->

The local Kind acceptance attempt was intentionally non-destructive: no
`*-down`, `stack-purge`, `cluster-down`, `teardown`, or real-cluster purge was
run.  The first committed-evidence checkpoint was
`aef616d4ae65ab4b4d9842c2b81864b58a998200`; local runtime mutation began only
after that SHA existed.

### Exact command/result ledger

| Machine tag | Status | Exact command | Meaningful observed assertion / result | Evidence location |
| --- | --- | --- | --- | --- |
| `P2-8-KIND-001` | PASS | `env LC_ALL=C LANG=C make cluster-up` | Created local `osramp`; `kubectl wait --for=condition=Ready node/osramp-control-plane --timeout=3m` passed. | Active local context `kind-osramp`; `scripts/create-kind-cluster.sh` |
| `P2-8-ZOT-001` | PASS | `env LC_ALL=C LANG=C make registry` | Applied Zot and waited until `deployment/zot` rolled out 1/1. | Namespace `registry`; `d2-osramp-fleet/local/zot.yaml` |
| `P2-8-FLUX-NEG-001` | PASS (negative) | `env LC_ALL=C LANG=C make flux-bootstrap` before publishing | Correctly failed: `OCIRepository/flux-system` reported `NAME_UNKNOWN` for `acme/fleet`; it did not falsely claim ready. | `flux-system/ocirepository/flux-system`; `d2-osramp-fleet/Makefile` |
| `P2-8-OCI-001` | PASS | `env LC_ALL=C LANG=C make push-local` | Published and locally Cosign-signed fleet, Bao, infrastructure, application, and portal artifacts. | `scripts/push-local.sh`; local Zot catalog (ephemeral port-forward) |
| `P2-8-FLUX-001` | PASS | `flux reconcile source oci flux-system -n flux-system --timeout=3m` then `flux reconcile kustomization flux-system -n flux-system --with-source --timeout=5m` | Fleet OCI source became `Ready=True`, `ArtifactInStorage=True`, `SourceVerified=True`; `kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=60s` passed. | `flux-system/ocirepository/flux-system`; `flux-system/fluxinstance/flux` |
| `P2-8-FLUX-TEST-001` | FAIL | `env LC_ALL=C LANG=C make flux-test` | Timed out waiting for `inf-bao/infra-controllers`; this is a real readiness assertion failure, not a command-only check. | `scripts/demo-lifecycle.sh`; `inf-bao/kustomization/infra-controllers` |
| `P2-8-BAO-ACCEPT-001` | BLOCKED | `DEMO_WAIT_TIMEOUT=30s env LC_ALL=C LANG=C make demo-bao-test` | Static Bao/SPIRE config passed, then runtime identity proof failed because namespace `fe-signalloom` was absent. No positive or negative workload identity claim is made. | `d2-signalloom/test/validate-bao-spire.sh`; `scripts/demo-lifecycle.sh` |
| `P2-8-PORTAL-ACCEPT-001` | BLOCKED | `DEMO_WAIT_TIMEOUT=30s env LC_ALL=C LANG=C make demo-signalloom-test` | Static 9/9 passed; runtime `signalloom-test` timed out on `inf-bao/infra-controllers`. `fe-signalloom` was never created, so no portal request/response walkthrough is claimed. | `d2-signalloom/test/{topology,portal-package,bootstrap,bao-spire}.bats`; `scripts/demo-lifecycle.sh` |
| `P2-8-LIFECYCLE-SAFETY-001` | PASS (harness) | `env LC_ALL=C LANG=C make test-demo-lifecycle` | 4/4 fake-kubectl checks prove a retained consumer or unavailable consumer query prevents purge, and force is required. It intentionally does not purge the live Kind cluster. | `test/demo-lifecycle.bats` |

### Artifact and status evidence

The three in-cluster OCI sources were both stored and signature-verified:

| Source | Revision | Stored artifact digest |
| --- | --- | --- |
| `flux-system/flux-system` | `latest@sha256:339e4f17ddb04b23f223e59e09fffbae8e5ce0a7912dab743f708ac500ec9c66` | `sha256:07501c61fb53cce8cbaa27d390256628b31229e65144ce61740bd29ece8b5eab` |
| `inf-bao/inf-bao` | `latest@sha256:56602f5ddf352e4fab53d24f4142e7085e9e311b8e22cdc935cee92c13b69dbe` | `sha256:aed66575f62b7d17f036266202c73a4d910a86a666ba47629b3a009c0e7cb9bd` |
| `inf-signalloom/inf-signalloom` | `latest@sha256:f85abd1f794973862eb376a456bb8bd0181e6c3eb2baaa382cacca5e76c8f3b3` | `sha256:3ab92770446ef3f82fbde21fa46d7ba74287cada710dc67c6aed5bb767769d04` |

`make signalloom-check`, `make signalloom-help`,
`make demo-signalloom-test-config`, `make -C d2-signalloom test`,
`bats test/signalloom-flux-integration.bats`, and `make test-demo-lifecycle`
all exited zero.  This file is the durable repository evidence index; live
cluster status is reproducible with the exact commands above while
`kind-osramp` remains present.

### Reproduced blockers and prioritized debugging

1. **P0 — Bao controller/config circular readiness:**
   `inf-bao/infra-controllers` health checking fails before
   `inf-bao/infra-configs` can apply.  SPIRE server and agent both emit
   `FailedMount`: ConfigMaps `spire-server-config` and `spire-agent-config`
   are absent, while `infra-configs` waits for `infra-controllers`.  Break
   this dependency cycle and add a runtime regression that asserts each
   controller's required ConfigMaps exist before its health check.
2. **P0 — OpenBao security-context startup:** `openbao` is
   `CrashLoopBackOff` with reproducible logs `su-exec: setgroups: Operation not
   permitted`; its image digest is
   `sha256:af40ca17625ec44aa1ffe3698f85162d71d9cc97adc9e97821ef393ac94b6e42`.
   Reconcile the pod security context with the image entrypoint, then require
   a live Ready condition before declaring Bao identity acceptance.
3. **P1 — invalid MinIO OCI chart reference:**
   `inf-signalloom/ocirepository/minio` requests
   `oci://registry-1.docker.io/minio/minio:8.0.10` and receives
   `MANIFEST_UNKNOWN`.  Pin a published chart tag/digest and add an OCI
   availability test; this blocks `minio`, hence the Signal Loom infra
   controller chain.
4. **P1 — bootstrap ordering diagnostics:** a bootstrap before `push-local`
   fails closed correctly.  Normal `make up` orders publication before
   bootstrap, but operators invoking individual targets need this dependency
   stated and an automated target-order test should cover it.  After a failed
   first bootstrap, `flux reconcile source oci flux-system -n flux-system` and
   `flux reconcile kustomization flux-system -n flux-system --with-source`
   reproduce recovery without teardown.

### Test-quality appraisal

The static suites and mocked lifecycle checks are useful regression guards, and
the real run proved that signature verification, source storage, FluxInstance
creation, source ordering failure, and readiness waits are observable rather
than assumed.  They are insufficient as release evidence: static portal and
identity assertions passed while the actual Bao dependency graph never became
ready; the current lifecycle test uses a fake kubectl; and no live portal
workflow, Bao positive identity, Bao negative identity, or idempotent
up/down-cycle result was possible.  Treat all of those as **blocked**, not
passed.  Do not run teardown/purge merely to manufacture lifecycle coverage;
first repair the P0 blockers, then execute a disposable-cluster acceptance
suite that asserts object readiness, denies the negative service account,
obtains the expected workload identity, performs a portal request, repeats a
non-destructive up operation for idempotency, and verifies guard behavior
without deleting live shared state.

## Re-baseline errata: Appendix B and Phase 3 review

<!-- machine-tag: P2-8-REBASE-REVIEW-2026-07-26T03:30:55+01:00 -->
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

The completed demo was re-baselined at `integration/signalloom-d2-v2.0.0`
(`48657aa8facd2ce6446877bac77d4b357b2d8ba2`) without modifying the proposal,
`board.json`, another worktree, or any external environment. Appendix B's
duplication guard and Phase 3's bounded bootstrap/identity requirements were
reviewed against the repository evidence:

- **Duplication boundary:** retain the existing controller and delivery owners;
  no second Flux, cert-manager, Kyverno, monitoring, or alternate source-policy
  owner is justified by the current evidence.
- **Phase 3 safety boundary:** keep bootstrap state disposable and local, use a
  dedicated non-critical consumer and service account, prove both allowed and
  denied access, and do not make backend, NATS, PostgreSQL, or workflow paths
  depend on the demo secret.
- **Shared-pattern decision:** reuse only the evidenced lifecycle/Make target
  and fail-closed purge patterns (`test/demo-lifecycle.bats`, 4/4), plus the
  existing static topology/dependency checks (9/9). No new generic abstraction
  or production secret path is introduced.
- **Qualification boundary:** this review passes as documentation/re-baseline
  evidence; the existing real-runtime Bao readiness and portal acceptance
  blockers remain blocked and are not promoted to release evidence.

Validation after the review passed: `make signalloom-check`,
`make demo-signalloom-test-config`, `make test-demo-lifecycle`,
`bats test/signalloom-flux-integration.bats`, and `git diff --check`.

## Demo-to-hosted threat-model errata

<!-- machine-tag: SIGNALLOOM-DEMO-HOSTED-THREAT-ERRATA-2026-07-26T04:59:53+01:00 -->
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

This ISO-offset errata records a repository-only, non-production review of
`demo-to-hosted-threat-model.md`. It is source-backed by the checked-in D2
portal code, deployment, report-store boundary, schema, and Make targets. It
adds no credentials, infrastructure, provider calls, or release authorization.

The review passes the Kanban documentation check because it assigns owners and
hosted promotion gates, identifies authorization/tenant isolation, report
access, secrets, ingress, egress, resilience, pod hardening, and artifact
integrity risks, and binds each to an explicit verification criterion. It does
not mark any hosted gate complete: the document deliberately treats every
required hosted control as a future, separately evidenced acceptance item.
