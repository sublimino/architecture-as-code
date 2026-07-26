# Signalloom Phase 1 pre-flight review

**Card:** SLDPB25-P1-PRE  
**Assessment date:** 2026-07-26  
**Integration ref:** `integration/signalloom-d2-v2.5.0`  
**Review boundary:** scope/prompts, baseline, journey/API/Dex ownership, duplication,
sequencing, and deterministic checks. No delivery features were implemented.

## Verdict

**`status=fail proceed=no blocking_drift=yes`**

The repository delivery baseline is green, but Phase 1 cannot safely proceed to
implementation as currently specified. The proposal requires a complete journey
matrix, local Dex contract, and mapped dashboard API; the reviewed evidence instead
proves only Flux reconciliation, deployment presence, topology, and fake-service
packaging. The missing contracts and the findings below are blocking review drift,
not implementation defects introduced by this card.

## Scope and prompt review

The proposal defines these Phase 1 acceptance surfaces:

| Prompt | Required evidence | Review result |
| --- | --- | --- |
| Journey inventory | Route, API, auth, error, and fake-integration matrix | **Missing**; no committed matrix or waiver ledger found |
| Initial tests | Browser, API, and infrastructure tests against baseline | **Partial**; infrastructure tests exist, product-flow tests do not |
| Dex authentication | Issuer, client, claims, tenant mapping, login/callback/logout/expiry | **Missing**; dashboard remains Auth0-specific |
| Dashboard/API compatibility | Each client call maps to handler, adapter, persistence, or waiver | **Blocked**; ownership and route gaps remain |
| Fake integrations | No browser path reaches external integrations or credentials | **Topology-only**; fake deployment configuration exists, browser proof does not |
| Dependent retest | `RETEST-1` depends on `TEST-1` and covers discovered failures | **Not yet applicable**; `TEST-1` product-flow evidence is absent |

The proposal's intended order is pre-flight → independent Phase 1 contracts →
Governor lock → implementation. This review confirms the order is directionally
correct, but the Phase 1 contract gate must remain closed until the missing evidence
is produced.

## Journey, API, and identity findings

### Journey dimensions

The required matrix must enumerate at least: dashboard route, API call, authenticated
state, unauthenticated state, expired-token state, validation/error state, persistence
transition, fake-integration interaction, and external-egress assertion. The current
runtime suite explicitly limits itself to Flux readiness and frontend deployment
presence (`d2-signalloom/test/runtime.bats:3-22`; `docs/signalloom/local-phase-1-lifecycle.md:17-23`).

### Dashboard/API ownership

- The dashboard client sends bearer-authenticated requests under `/api/*`
  (`/home/andy/src/cp/platform/dashboard/src/api/client.ts:28-47`).
- Connector calls include `GET`, `POST`, and `DELETE` operations
  (`/home/andy/src/cp/platform/dashboard/src/api/connectorsClient.ts:60-88`).
- The shared dashboard gateway only declares `GET` and `POST` for connector paths;
  its own comment records that `DELETE /connectors/{id}` is not reachable
  (`/home/andy/src/cp/platform/services/api_gateway/routers/proxy_dashboard.py:49-59`).
- The existing discovery portal exposes a separate `/api/discovery/*` surface and
  is not an implementation of the dashboard contract. No committed adapter or
  ownership map connects the two surfaces.

**Required Phase 1 decision:** assign each dashboard API family to the platform API,
the local compatibility service, a fake adapter, or an explicit waiver. Record the
gateway method coverage as part of that contract.

### Dex/OIDC ownership

The dashboard currently reads `VITE_AUTH0_DOMAIN`, `VITE_AUTH0_CLIENT_ID`, and
`VITE_AUTH0_AUDIENCE` from `Auth0Provider.tsx:38-55`. No Dex issuer, client
registration, JWKS/discovery contract, claims-to-tenant mapping, or deterministic
local credential contract is present in the reviewed repository. Dex therefore
cannot be treated as an already-owned baseline capability.

**Required Phase 1 decision:** name the Dex/identity owner and commit issuer URL,
client ID/redirect URI, issuer/audience/expiry claims, tenant mapping, and negative
auth cases before API implementation expands scope.

## Ownership and source-of-truth review

| Boundary | Observed owner/source | Decision required |
| --- | --- | --- |
| Dashboard source | External `signal-loom/platform/dashboard/` | Signal Loom platform team owns source; D2 owns integration artifact |
| Local D2 delivery | `d2-signalloom/{apps,infra,fleet}` | ControlPlane platform delivery owns packaging and Flux boundaries |
| Discovery portal | Existing `d2-signalloom/apps/fe-signalloom` runtime contract | Keep as a separate portal boundary; do not silently make it the dashboard API |
| API compatibility | No committed local handler/adapter map | Name accountable API owner before implementation |
| Dex/OIDC | No local implementation or named owner | Assign identity owner and freeze contract first |
| Journey/test evidence | `d2-signalloom/test` infrastructure checks only | Testing owner must add matrix, browser/API cases, and waivers |

The ResourceSet source is duplicated at
`d2-signalloom/fleet/local/signalloom.yaml` and
`d2-osramp-fleet/tenants/local/signalloom.yaml`. The first file calls itself
canonical while explaining the active fleet consumes the second copy
(`d2-signalloom/fleet/local/signalloom.yaml:1-3`). The copies are currently identical
according to the existing topology test, but no drift-enforcement mechanism was
found. Choose one canonical authoring location and generate or verify the consumer
copy; do not add a third copy.

## Sequencing and shared patterns

The clean local lifecycle documents Bao → Signal Loom infrastructure → frontend
(`docs/signalloom/local-phase-1-lifecycle.md:3-15`) and the script performs the same
bounded sequence (`scripts/signalloom-local.sh:58-69`). This is a useful shared
pattern: one deterministic orchestration path, explicit waits, and no unrelated
OSRAMP workloads.

Two sequencing qualifications remain:

1. `signalloom-apps` depends on `inf-signalloom/infra-configs`, but its
   `readyExpr: status.observedGeneration >= 0` at
   `d2-signalloom/fleet/local/signalloom.yaml:142-148` does not demonstrate that
   the dependency is Ready. Replace the assumption with a tested readiness
   condition or document why the expression is sufficient.
2. `scripts/signalloom-local.sh` is the clean-cluster lifecycle, while
   `scripts/signalloom-up.sh` patches/restores an existing ResourceSet. Their
   evidence scopes differ; do not report either path as proof of the other.

Reusable patterns for follow-on cards:

- Run `make signalloom-check` before workload creation or application.
- Keep logical D2 sources as separate signed OCI and Flux reconciliation boundaries.
- Use namespace-scoped tenant identities and default-deny policy assertions.
- Keep fake integrations internal and deterministic for local evidence.
- Record command, exit code, revision, environment, timestamp, and result in each
  proposal erratum.

## Deterministic evidence

All commands below were run in the isolated worktree on the stated integration ref.

```text
git merge-base --is-ancestor main integration/signalloom-d2-v2.5.0       # 0
git merge-base --is-ancestor 50831957e84c9889ad686cc399a2105d8450db3a HEAD # 0
env LC_ALL=C LANG=C make signalloom-check                                # 0
env LC_ALL=C LANG=C bats test/signalloom-local-lifecycle.bats test/signalloom-preflight.bats # 0 (8/8)
env LC_ALL=C LANG=C make -C d2-signalloom test                          # 0 (20/20)
bash -n scripts/signalloom-contract-check.sh scripts/signalloom-preflight.sh scripts/signalloom-local.sh scripts/signalloom-up.sh scripts/signalloom-down.sh agent/harness.sh # 0
git diff --check                                                          # 0
```

The checks validate delivery wiring and D2 topology. They do **not** validate the
dashboard journey, Dex, API compatibility, persistence semantics, or browser egress.
No cluster provisioning, external credential use, production data, board edit, push,
or PR was performed.

## Required next gate

Do not start Phase 1 implementation until the Governor accepts a committed journey
matrix, API ownership/waiver map, Dex/OIDC contract, ResourceSet source-of-truth
decision, and a test proving the actual dependency-ready sequencing. Then create
`TEST-1` evidence against those locked contracts; `RETEST-1` remains downstream.
