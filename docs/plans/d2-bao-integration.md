# D2-BAO Integration Plan for OSRAMP

## Purpose

Extend the existing OSRAMP local D2 demonstration so that OpenBao can run as a
first-class, Flux-managed platform capability. The integration must preserve
OSRAMP's current delivery invariants:

- Flux consumes signed OCI artefacts rather than Git at runtime.
- Local Kind uses Zot plus local Cosign keys, while hosted environments retain
  the OIDC identity-verification model.
- Fleet, infrastructure and application tenants remain separately owned and
  reconciled as logical source directories in this monorepo.
- Existing OSRAMP demo flows remain runnable without OpenBao during the
  incremental rollout.

This is an integration plan, not approval to copy D2-BAO wholesale or to make
OpenBao mandatory for every current OSRAMP component.

## Current baseline

OSRAMP already supplies the right substrate:

| Concern | Current OSRAMP location | Existing behaviour |
| --- | --- | --- |
| Local lifecycle | `Makefile`, `scripts/setup.sh`, `scripts/push-local.sh` | Creates Kind, Zot and signing material; pushes and signs local OCI artefacts; bootstraps Flux; loads images and waits for reconciliation. Zot data is persisted through a Kind host mount at `ZOT_CACHE_DIR` (default `.cache/zot`), so `make down && make up` reuses OCI data. Use `make zot-cache-reset` for an empty-registry test and reserve `make teardown` for a trust-root reset. |
| Fleet | `d2-osramp-fleet/` | FluxInstance, Flux Operator, environment runtime contract, tenant ResourceSets and OCI source verification. |
| Infrastructure | `d2-infra/` | cert-manager, Envoy Gateway, kube-prometheus-stack, metrics-server, Trivy and environment overlays. |
| App tenant | `d2-osramp-apps/` | OSRAMP frontend/backend base and local/staging/production overlays. |
| Supply chain | Root README and component CI | OCI artefacts are signed; hosted policy binds verification to workflow/ref; local verification uses the generated Cosign public key. |

D2-BAO adds an OpenBao-focused reference composition:

- OpenBao server and agent injector;
- cert-manager issuers and trust bundles for OpenBao;
- Kyverno policies, including image-verification policy;
- Secrets Store CSI driver;
- optional SPIRE/SPIFFE and trust-manager patterns;
- application examples that consume secrets through the injector;
- dedicated controller/configuration layers and signed OCI components.

The source reference is `/home/andy/src/cp/d2-bao-apps`. Do not consume its
working tree directly at runtime; adapt selected components into OSRAMP's logical
source directories and publish them through OSRAMP's own OCI/signing contracts.

## Target architecture

```text
Flux Operator / FluxInstance
        |
        +-- infra tenant: cert-manager -> trust material -> OpenBao prerequisites
        |                   -> OpenBao server -> OpenBao bootstrap/configuration
        |                   -> injector / CSI driver -> observability / policy
        |
        +-- apps tenant: OSRAMP workloads
                            -> service-account scoped OpenBao auth
                            -> injector or CSI-delivered secrets
```

### Architectural decisions

1. **Adopt OpenBao incrementally.** The first deliverable is an isolated
   `openbao-system` platform capability plus a non-critical demo consumer; it
   must not replace existing OSRAMP configuration/secrets at once.
2. **Keep D2 ownership boundaries.** Cluster add-ons and OpenBao live in
   `d2-infra`; workloads consuming secrets live in `d2-osramp-apps`; cluster
   bootstrap and tenant wiring live in `d2-osramp-fleet`.
3. **Make bootstrap idempotent.** The OpenBao initialisation/configuration Job
   must use an apply policy that prevents Flux from resealing, reinitialising or
   regenerating credentials during reconciliation. Reconcile and recovery
   semantics must be designed before a secret is entrusted to it.
4. **Choose storage deliberately.** A local Kind proof may use the D2-BAO
   reference's Raft-oriented model. Any hosted persistence choice—Raft PVC,
   CNPG/PostgreSQL, backup target and recovery objective—requires a separate
   decision record and restore exercise.
5. **Use workload identity, not static developer tokens.** Start with
   Kubernetes service-account auth and narrowly scoped policies. SPIFFE/SPIRE
   is a later enhancement, not an initial hard dependency.
6. **Prove the whole trust chain.** The OpenBao manifests and every demo image
   must pass OSRAMP's existing OCI/Cosign source verification and Kyverno image
   verification. Local exceptions must be narrow and explicit.

## Delivery sequence

### Phase 0 — compatibility and decision record

Before changing manifests, create a short ADR answering:

- Which D2-BAO components will be adopted now: OpenBao server, injector,
  cert-manager trust material, Kyverno and CSI driver.
- Which are deferred: SPIRE/SPIFFE, external secrets patterns, HA/production
  storage, migration of all existing secrets and multi-cluster replication.
- Local topology: namespaces, local domain/certificates, storage class, seeded
  demo secret, service accounts and expected OpenBao policies.
- Recovery contract: bootstrap state, seal/unseal procedure, root/recovery-key
  handling, backup ownership and the condition under which the local cluster is
  intentionally disposable.
- Conflict resolution: naming, CRD versions and controller ownership where
  OSRAMP and D2-BAO already provide cert-manager, monitoring or policy
  components.

**Exit criteria:** an approved component matrix and an architecture diagram
showing reconciliation dependencies; no duplicated controller is planned.

### Phase 1 — create the D2 infrastructure composition

Add dedicated D2-BAO-derived components under `d2-infra/components/`, retaining
the existing `controllers/<environment>` and `configs/<environment>` split:

1. `openbao-server` controller and configuration layers.
2. `openbao-agent-injector` controller and configuration layers.
3. OpenBao-specific cert-manager issuers/trust bundles, extending rather than
   duplicating OSRAMP's current cert-manager installation.
4. Kyverno only after comparing it with OSRAMP's current admission approach;
   one controller/policy owner, not two.
5. Secrets Store CSI driver only when a concrete OSRAMP consumer needs mounted
   secret material; injector consumption is enough for the first demo.

Create Kustomizations with explicit `dependsOn` order:

```text
cert-manager controller
  -> cert-manager OpenBao issuer/trust configuration
  -> OpenBao server controller
  -> OpenBao server configuration/bootstrap
  -> injector controller/configuration
  -> OpenBao demo consumer
```

Monitoring, NetworkPolicy, PodSecurity and resource limits are part of every
new workload definition, not follow-up work.

**Exit criteria:** `kustomize build` and repository validation pass for all
affected local overlays; the infrastructure tenant's dependency graph is
explicit and has no cyclic dependency.

### Phase 2 — local artefact and fleet integration

Extend the OSRAMP artefact process rather than adding a parallel delivery path:

- Add OpenBao component artefact packaging/signing to the existing `d2-infra`
  workflow and local `push-local` flow.
- Add any required local registry aliases/image loading to the root Makefile.
- Add `flux-runtime-info` substitutions only for values which genuinely vary by
  environment: registry, domain, artifact tag, identity and local public key.
- Extend the infra tenant ResourceSet to reconcile the new component OCI
  sources and Kustomizations.
- Do not add a second FluxInstance, second Flux Operator or an alternate source
  verification policy for D2-BAO.

**Exit criteria:** `make up` from a clean machine reaches a healthy shared
foundation without activating demo workloads. `make demo-bao-up` then reaches a
healthy `openbao-system`; `flux get all -A` shows the explicitly activated Bao
sources and Kustomizations Ready.

### Phase 3 — bootstrap, identity and demo consumer

Implement an explicit bootstrap lifecycle:

1. OpenBao server starts and reaches a sealed/initialisable state.
2. A one-time/idempotent bootstrap job initialises the local instance and stores
   only the material required for the disposable local demo.
3. A configuration job enables Kubernetes auth, creates the OSRAMP demo policy
   and binds a dedicated demo service account to that policy.
4. A non-critical OSRAMP demo workload consumes one non-production value through
   the OpenBao injector.
5. A positive test proves secret availability; negative tests prove a different
   namespace/service account cannot read it.

The first consumer should be a small dedicated demo deployment or an isolated
feature of an existing app. Do not make the OSRAMP backend, NATS, PostgreSQL or
workflow engine depend on OpenBao until the recovery and rollout path is proven.

**Exit criteria:** injector template resolves a seeded demo secret; unauthorised
access is denied; workload restart and Flux reconciliation do not regenerate
bootstrap state.

### Phase 4 — policy, observability and failure testing

Add objective proof that the new platform component is safe to demonstrate:

- Kyverno rejects an unsigned/non-compliant OpenBao consumer image while
  accepting the signed local/hosted identity as appropriate.
- NetworkPolicies deny all traffic to OpenBao except required clients,
  monitoring and cert-manager paths.
- Prometheus scrapes server/injector metrics and Grafana exposes a useful
  health/seal/error dashboard.
- Tests cover restart, reconciliation, policy denial, bad Kubernetes auth,
  missing secret, wrong namespace and local cluster rebuild.
- Document reset and disaster-recovery expectations: for local, a clean rebuild
  is valid; for hosted, a restore drill is mandatory before storing any
  non-demo credential.

**Exit criteria:** automated tests pass in CI/local Kind; a short operator
runbook explains initialisation, normal reconciliation, reset and failure
diagnosis.

## Work breakdown

| Workstream | Primary changes | Acceptance evidence |
| --- | --- | --- |
| Repository comparison | ADR, component mapping, version/CRD conflict matrix | Approved decision record |
| OpenBao platform | `d2-infra/components/openbao-*` base/local overlays | Flux Ready; sealed/init lifecycle verified |
| Certificate trust | Extend existing cert-manager configuration | TLS validation from injector/consumer to OpenBao |
| Fleet wiring | Infra tenant ResourceSet, OCI sources, `dependsOn` graph | Fresh Kind reconcile succeeds |
| Artefact pipeline | Component packaging, local push/sign and CI validation | Only signed artefacts reconcile |
| Consumer example | Dedicated service account, policy and demo deployment | Allowed secret read and denied cross-namespace read |
| Guardrails | Kyverno, NetworkPolicy, PSS, resource controls | Negative admission and connectivity tests |
| Operations | Metrics, dashboard, reset/recovery docs | Operator drill and documented evidence |

## Acceptance test matrix

| Scenario | Expected result |
| --- | --- |
| Clean `make up` | Shared foundation reaches Ready without demo workloads or manual kubectl mutation. |
| Explicit `make demo-bao-up` | `openbao-system` reaches Ready after opt-in activation. |
| Local signed source | Flux accepts the local Zot/OpenBao artefact signed by the generated local key. |
| Untrusted source | Fleet policy rejects a tenant source outside the allowlist. |
| Bootstrap re-reconcile | Reconciliation does not reinitialise/reseal or rotate bootstrap material. |
| Authorised consumer | Dedicated OSRAMP service account receives only its allowed demo secret. |
| Unauthorised consumer | Different namespace/service account receives denial and no secret data. |

| Unsigned image | Kyverno/admission rejects it. |
| Network-deny | Pod outside the approved path cannot reach OpenBao. |
| Reset | Documented local teardown/rebuild returns to a known baseline. |
| Existing demo regression | Current OSRAMP `make test` and workload checks continue to pass with OpenBao disabled and enabled. |

## Risks and non-goals

| Risk | Control |
| --- | --- |
| Duplicated cert-manager, Kyverno or monitoring controllers | Compare current OSRAMP components first; extend the existing owner rather than import a duplicate. |
| Bootstrap secrets accidentally committed or published | Use generated local-only material, `.gitignore`, sealed/external mechanisms as appropriate; add secret scanning. |
| Flux repeatedly changes OpenBao initialisation state | Isolate bootstrap in an idempotent Job and use server-side apply behaviour designed for one-time state. |
| Local demo treated as production secrets system | Label it disposable; require storage/backup/restore ADR and exercise before any hosted credential. |
| Scope expands into all application secrets | Restrict first increment to one seeded non-critical secret consumer. |
| Signature policy blocks local development | Reuse OSRAMP's local key/distribution path; test it rather than bypass verification. |

Non-goals for the first implementation are production HA, enterprise backup/DR,
all application-secret migration, multi-cluster replication, and SPIFFE/SPIRE
enforcement.

## Immediate next implementation slice

1. Create the Phase 0 ADR and a component conflict matrix.
2. Inspect current `d2-infra` cert-manager/admission layout against the
   corresponding D2-BAO components.
3. Add a local-only `openbao-system` component with server, bootstrap and
   health/metrics resources—without connecting any existing OSRAMP application.
4. Wire it through the existing infra tenant and OCI local-signing path.
5. Add a dedicated demo consumer and the acceptance tests above.

Only after this slice passes should injector/CSI integration reach a real
OSRAMP service.

## Proposal errata — partial Phase 2 recovery integration

2026-07-26: partial Phase 2 recovery integration completed in the Governor
worktree. Qualified P2-7 recovery commit `efe6c0d187bdd255d38ed55b0f69cd8d3e01766d`
was merged with `--no-ff` into `integration/signalloom-d2-v2.0.0`; its merge
parent is the requested integration baseline
`97efebaf94180beefc267011d85b9fb9dfe2498e`. The recovery corrects Zot
non-root cache initialisation compatibility and adds regression coverage for
existing-cluster cache preparation.

Validation passed:

- `make signalloom-check`
- `make test-zot-cache test-demo-lifecycle` — 3/3 and 4/4
- `make -C d2-signalloom test` — 9/9
- `make -C d2-signalloom bao-test-config`
- `shellcheck` on all shell files changed by `efe6c0d`
- `git diff --check` against the merge parent and integration baseline

This is partial integration evidence only; no Gates C/D/E or release approval
is claimed. P2-8 must revalidate from the resulting clean integration HEAD.

<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

## Proposal errata — SLDPB25-P1-1 dashboard browser baseline

2026-07-27: the Estate 95 dashboard journey matrix now identifies the login,
dashboard view, scan initiation, and results-display boundaries and maps each
to browser coverage. Login remains a Dex contract because the local dashboard
broker deliberately has no session middleware. The scan tests intercept the
LLM Guard API response to verify dashboard request and rendering behavior
without claiming live scanner availability.

- Matrix and Playwright baseline commit:
  `8c5e575a8575358db762b0362603395a0cfb2620`
- Test command: `cd test/acceptance && bunx playwright test --config=playwright.config.ts dashboard-journey.spec.ts`
- Result: `7 passed (3.2s)`, exit `0`.
- Browser skill diagnostic session could not start locally; Playwright supplied
  the actual browser evidence and retained failure diagnostics during selector
  refinement.

Follow-up source reconciliation corrected two non-functional matrix labels:
`/ws/term` is a WebSocket upgrade rather than an HTTP GET, and the current
ServiceNow window consumes the incident collection while rendering detail
locally. A fresh baseline on the current integration HEAD reran the seven
dashboard journeys successfully: `7 passed (3.6s)`, exit `0`.

<!-- machine-tag: SLDPB25-P1-1-DASHBOARD-BASELINE-2026-07-27T12:26:00+01:00 -->
<!-- kanban-check: status=pass proceed=yes blocking_drift=no scope=dashboard-browser-baseline -->

## Proposal errata — SLDPB25-P1 Governor canonical contract lock

2026-07-27: Governor inspection found the approved Phase 1 contract evidence
already reachable from `integration/signalloom-d2-v2.5.0`; no redundant merge
was manufactured. The canonical Phase 1 implementation contracts are:

- Journey matrix: `docs/signalloom/dashboard-journey-matrix.md`, source commit
  `8c5e575a8575358db762b0362603395a0cfb2620`, recorded by merge commit
  `4def85209e851b03b534863b82529aea962dc7c3`.
- API contract inventory: `docs/signalloom/api-contract-inventory.md`, source
  commit `ba78f050a551d56de0fa6ab9db93cfadc60c0ab9`; its field-validation
  evidence is commit `184636134470dd5ceef1e206bfeccb9ee1fb7178`.
- Dex/OIDC design: `docs/signalloom/dex-oidc-design.md`, source commit
  `55a6e79ca2963373a7215cbf6d97ddb752c83f94`; reconciled by merge commit
  `f8265df71ac2cf3a1a7b2019b7f4978bb278c7ec`.

Post-inspection validation passed on the Governor integration HEAD:

- `cd tools/demo-console && go test -count=1 ./...` — exit `0`.
- `make signalloom-contract-check` — exit `0`; release-pack and delivery
  contract guards passed for `main → integration/signalloom-d2-v2.5.0 →
  osramp-demo`.

Existing unrelated `MEMORY/WORK/` modifications were deliberately excluded.
No `board.json` modification, remote push, or pull request was performed.

<!-- machine-tag: SLDPB25-P1-GOV-CANONICAL-CONTRACT-LOCK-2026-07-27T14:45:00+01:00 -->
<!-- kanban-check: status=pass proceed=yes blocking_drift=no scope=phase-1-canonical-contract-lock -->
