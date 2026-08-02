# RBAC Explorer / Importer — Live Cluster Wiring

> Verified against the running `osramp` KinD cluster, 2026-08-02. See also
> `docs/signalloom/kubesec-afm-guide.md` (AFM access/architecture) and
> `docs/signalloom/kubesec-afm-live-test-status.md` (the CronJob import path
> this doc builds on).

## What this covers

The dashboard has three RBAC-facing surfaces, all backed by the KubeSec-AFM
platform (`afm-platform.fe-k8s-afm`):

| Surface | File | API path |
|---|---|---|
| RBAC importer panel (generates AFM import YAML) | `RbacImporterPanel.tsx` | `/afm/*` — direct AFM proxy |
| RBAC Analysis (embeds AFM's own dashboard) | `RbacAnalysisPage.tsx` | `/afm/*`, `/dashboard/` — direct AFM proxy |
| RBAC Explorer (native Signal Loom view) | `RbacExplorerPage.tsx` | `/api/rbac/*` — intermediate correlation API |

The importer and analysis-iframe pages talk to AFM through nginx's
unauthenticated `/afm/*` proxy — read-only, GET-only, no secrets involved,
already covered by `RbacAnalysisPage.test.tsx` (18 tests) against realistic
AFM wire fixtures. **They were not changed by this work.**

The RBAC Explorer is the page this document is about. It used to fetch
AFM's four endpoints (`rbac`, `analysis/latest`, `rbac/conformance`,
`analysis/shared_roles`) directly from the browser and join them
client-side, against an assumed wire shape that had never been checked
against a live cluster.

## The bug

Captured directly from the live `osramp` cluster (commands below), against
what `RbacExplorerPage.tsx` assumed:

| Field the page read | Reality | Effect |
|---|---|---|
| `analysis.escalation_paths` | Does not exist. Real keys are `single_escalations` and `group_escalations`. | **"Escalation Paths" stat always read 0**, even when AFM's Z3 engine found 3 real privilege-escalation paths (`admin_via_impersonation`, risk level `high`, score 48) on this cluster. |
| `conformance[i].namespace` / `.details` | Absent at the top level. The role identity is nested under `conformance[i].role` (`{name, scope, namespace}`); there is no `details` field at all. | Namespace and Details columns rendered `—` on every real row. |
| `shared_roles.results[i].shared_by` / `.risk` | Absent. Real fields are `all_subjects` (a list — the count is its length) and `privileged_subjects`; there is no risk/reason field. | Shared-Role Pivot Points table rendered `undefined subjects` on every row. |

A security-posture dashboard silently reporting "no escalations" when there
are three is a worse failure mode than one that errors visibly — this was a
false negative, not a cosmetic rendering bug.

Root cause: AFM's escalation/admin lists reference subjects by AFM's own
internal id (`sa_fe_signalloom_flux`), not the plain Kubernetes identity
(`flux`, namespace `fe-signalloom`) the RBAC payload uses. Resolving one to
the other requires `analysis.metadata.name_map`
(`{"sa_fe_signalloom_flux": "ServiceAccount/fe-signalloom/flux", ...}`), a
join that only makes sense to do once, against one pinned understanding of
the wire format — not independently re-derived in every browser tab.

## Fix: server-side correlation

`d2-signalloom/apps/fe-signalloom/src/rbac_correlation.py` calls AFM's four
endpoints server-side, resolves the internal-id → k8s-identity join via
`name_map`, and returns one backend-owned contract. The parsing and
correlation logic (`correlate_rbac()`) is pure and unit-tested against the
real captured shapes in `tests/test_rbac_correlation.py` — the regression
test `test_correlate_rbac_resolves_escalation_by_afm_internal_id` fails if
this correlation is ever removed.

### Endpoint contract

```
GET /api/rbac/clusters
    -> [{"id": str, "name": str}, ...]

GET /api/rbac/clusters/{cluster_id}/correlated
    -> {
         "cluster": {"id": str, "name": str},
         "namespaces": [str, ...],
         "subjects": [{"name", "kind", "namespace"?, "is_admin", "is_escalation_actor"}, ...],
         "roles": [{"name", "scope", "namespace"?, "rules", "conformance_issue_count", "shared_by_count", "has_privileged_sharing"}, ...],
         "bindings": [{"name", "scope", "namespace"?, "role_ref", "subjects"}, ...],
         "escalations": [{"kind": "single"|"group", "subject", "subject_display"?, "escalation_type"?, "risk_level"?, "risk_score"?, "summary"?}, ...],
         "conformance": [{"role_name"?, "role_scope"?, "role_namespace"?, "severity"?, "reason"?}, ...],
         "shared_roles": [{"role_name", "role_scope", "role_namespace"?, "shared_by", "subjects", "privileged_subject_count"}, ...],
         "admin_count": int,
         "non_admin_count": int
       }
```

Both routes require the same Dex-issued Bearer JWT as every other `/api/*`
route (see the parent README's Auth section) — a change from the
importer/analysis pages' unauthenticated `/afm/*` calls, and consistent with
how the rest of `fe-signalloom-api` works.

**Failure mode is deliberately fail-closed, not fail-open.** An unreachable
or malformed AFM RBAC response returns `503` with
`{"error": {"code": "afm_unreachable" | "afm_bad_response", "message": ...}}`.
This differs from `/api/health/crypto`'s pattern (swallow the error, return
an empty-but-200 result) on purpose: an empty-but-200 security posture looks
identical to "genuinely nothing found," which is the wrong default for a
security tool. Analysis/conformance/shared-role enrichment is treated more
leniently — a cluster can be imported before its Z3 analysis job has run, so
those three degrade to empty lists on individual failure rather than failing
the whole request; only the RBAC payload itself is load-bearing.

The frontend (`src/api/rbacCorrelationApi.ts`, consumed by
`RbacExplorerPage.tsx`) mirrors this: a live-mode fetch failure renders a
visible error banner (`data-testid="rbac-live-error"`) with a Retry button —
**it never substitutes demo fixtures for a live cluster that failed to
load.** Demo mode is a separate code path that never issues a network
request at all (see `RbacExplorerPage.test.tsx`, "never issues a network
request in demo mode").

## Required RBAC / network access

Two separate privilege boundaries are involved; neither the browser nor the
dashboard nginx pod ever holds a Kubernetes credential.

**1. AFM's own read of the live cluster** (unchanged by this work — already
existed): the `afm-cluster-import` CronJob in `fe-k8s-afm`
(`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml`) runs as service
account `afm-cluster-reader`, bound to a dedicated `afm-rbac-reader`
ClusterRole:

```yaml
rules:
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["namespaces", "serviceaccounts"]
    verbs: ["get", "list"]
```

Read-only, RBAC-resource-scoped, no wildcards. Runs every 30 minutes,
POSTs the converted payload to AFM's own `/clusters/import`.

**2. fe-signalloom-api's reach to AFM** (new, added by this work): the API
pod calls AFM over HTTP only — it makes no Kubernetes API calls of its own,
so it needs no ClusterRole. It does need network reachability, which is
default-denied in this namespace. Added to
`d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml`
(`allow-portal-dependencies`, selector `bao.controlplane.io/consumer:
fe-signalloom`):

```yaml
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: fe-k8s-afm
  ports:
    - protocol: TCP
      port: 8000
```

`afm-platform` itself carries no ingress-restricting NetworkPolicy (see
`d2-k8s-afm/apps/afm-platform/base` — no `networkpolicy.yaml` there), so no
matching ingress rule was needed on the AFM side; the dashboard's own nginx
pod already reaches AFM cross-namespace the same way for `/afm/*`.

No kubeconfig, service-account token, or Kubernetes credential of any kind
reaches the browser or the dashboard's nginx pod at any point in this path.

## Live vs demo mode

| | Demo mode | Live mode |
|---|---|---|
| Network calls | None — `buildFakeCorrelated()` fixture used directly | `GET /api/rbac/clusters` then `GET /api/rbac/clusters/{id}/correlated`, Bearer-authenticated |
| On AFM unreachable | N/A (no network call is made) | Visible error banner + Retry button; **no fallback to demo fixtures** |
| Escalation/conformance/shared-role data | Static, illustrative fixture (1 escalation, 2 conformance issues, 2 shared roles) | Real Z3 engine output for whichever cluster is selected |
| Cluster selector | `demo` only | Whatever AFM has imported — `local` (the running KinD cluster, imported every 30 min) plus any manually seeded clusters |

## Verifying against a local cluster

These are the exact commands used to reproduce the bug and verify the fix
against the running `osramp` KinD cluster (`kubectl config current-context`
should read `kind-osramp`).

```bash
# 1. Confirm the CronJob has actually imported live data as cluster "local"
kubectl -n fe-k8s-afm get cronjob afm-cluster-import
kubectl -n fe-k8s-afm port-forward svc/afm-platform 18000:8000 &
curl -s http://localhost:18000/clusters | jq '.[] | select(.id=="local")'

# 2. Inspect AFM's real wire shape directly — this is how the bugs above
#    were found and how the correlate_rbac() fixtures were derived
curl -s http://localhost:18000/clusters/local/analysis/latest | jq '.single_escalations, .group_escalations'
curl -s http://localhost:18000/clusters/local/rbac/conformance | jq '.[0]'
curl -s http://localhost:18000/clusters/local/analysis/shared_roles | jq '.results[0]'

# 3. Confirm the dashboard's nginx proxy reaches AFM (importer/analysis path)
kubectl -n fe-signalloom port-forward svc/dashboard-signalloom 18002:8080 &
curl -s http://localhost:18002/afm/clusters/local/rbac | jq '.subjects | length'

# 4. Backend unit + HTTP tests for the correlation layer (no cluster needed —
#    fixtures are the captured real shapes above)
cd d2-signalloom/apps/fe-signalloom/src
uv run --python 3.12 --with pytest --with pytest-asyncio \
  --with-requirements requirements.txt python -m pytest -v tests/test_rbac_correlation.py

# 5. Frontend tests + typecheck
cd d2-signalloom/apps/dashboard-signalloom
bun install
bun run typecheck
bun run test -- --run

# 6. End-to-end: rebuild the API image, load it into the KinD node, point the
#    deployment at it, mint a real Dex token (password grant, matching
#    oidc.tsx's scope so `aud` includes signalloom-api), and call the new
#    route through the dashboard's actual nginx proxy.
docker build -t <tag> d2-signalloom/apps/fe-signalloom
kind load docker-image --name osramp <tag>
kubectl -n fe-signalloom set image deploy/fe-signalloom discovery-portal=<tag>
kubectl -n fe-signalloom rollout status deploy/fe-signalloom
kubectl -n fe-signalloom port-forward svc/dashboard-signalloom 18021:8080 &
TOKEN=$(curl -s -X POST http://localhost:18021/dex/token \
  --data-urlencode grant_type=password \
  --data-urlencode username=demo-user@signalloom.local \
  --data-urlencode password=demo-user \
  --data-urlencode "scope=openid profile email groups audience:server:client_id:signalloom-api" \
  --data-urlencode client_id=signalloom-dashboard \
  | jq -r '.id_token')
curl -s http://localhost:18021/api/rbac/clusters/local/correlated \
  -H "Authorization: Bearer $TOKEN" | jq '.escalations | length'
```

**This was run to completion against the live `osramp` cluster.** Steps
1–5 passed as described. Step 6 required two fixes discovered only by
running it — both are captured here because they will recur for the next
person who redeploys this app on this shared cluster:

- **Concurrent agents on this shared cluster tag images identically.**
  Other agents are actively building and pushing
  `zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest`
  concurrently; a `docker build … :latest` followed shortly after by
  `kind load` and a rollout landed a **different agent's image** in the
  pod (confirmed by `docker cp`-inspecting the running container's
  filesystem: no `rbac_correlation.py` present despite a successful local
  build). Building to a throwaway unique tag
  (`:rbac-live-wiring-verify`), pointing the deployment at that tag,
  verifying, then reverting the deployment back to `:latest` avoided
  clobbering their in-flight work while still proving the real code path.
- **The `allow-portal-dependencies` NetworkPolicy edit did not apply via
  `kubectl apply -k local`** — `kubectl` reported `unchanged` while the
  live object provably lacked the new egress rule (and a stray retry
  without an explicit `-n` created a duplicate object in the `default`
  namespace, since the extracted fragment had no `metadata.namespace` —
  cleaned up). A direct `kubectl -n fe-signalloom patch networkpolicy
  allow-portal-dependencies --type=json` with an explicit JSON-patch
  `add` on `/spec/egress/-` is what actually landed the rule. Confirmed
  in the checked-in kustomize output (`kubectl kustomize local`) that the
  *source* was already correct; the gap was purely in how it reached the
  live object, not in the YAML.

**Result**, cluster `local` (the actual running KinD cluster, imported by
the existing CronJob), authenticated as `demo-user@signalloom.local`
through the real Dex password grant and the dashboard's real nginx proxy:

```
subjects: 92  roles: 138  bindings: 122
escalations: 3
  ServiceAccount/fe-signalloom/flux   high  48.0  reaches all on * at cluster scope through 2 modeled steps
  ServiceAccount/inf-bao/flux         high  48.0  reaches all on * at cluster scope through 2 modeled steps
  ServiceAccount/inf-signalloom/flux  high  48.0  reaches all on * at cluster scope through 2 modeled steps
conformance: 39
shared_roles: 4
admin_count: 10  non_admin_count: 82
subjects flagged is_escalation_actor: exactly the 3 flux ServiceAccounts above
```

This is the fix, proven end-to-end: the old client-side-stitched Explorer
would have shown `0` escalations for this exact cluster state. The
deployment was reverted to `:latest` and the temporary verification image
removed after capturing this result, to avoid leaving the shared cluster on
a throwaway tag; the NetworkPolicy patch was left in place since it is a
pure, non-destructive addition that matches what the checked-in YAML now
declares.
