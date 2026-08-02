# KubeSec-AFM Live Test Status

> Verified: 2026-08-02 | Cluster: KiND `osramp` at `127.0.0.1:37171`

## Deployment State

| Resource | Namespace | Status |
|----------|-----------|--------|
| `afm-platform` Deployment | `fe-k8s-afm` | 1/1 Running |
| `afm-platform` Service | `fe-k8s-afm` | ClusterIP `10.96.100.212:8000` |
| `afm-cluster-import` CronJob | `fe-k8s-afm` | Active, `*/30 * * * *` |

## Endpoint Verification

| Endpoint | Method | Result |
|----------|--------|--------|
| `/health` | GET | `{"status":"ok"}` |
| `/clusters` | GET | 5 clusters: prod, demo, sample1, usage_sample, local |
| `/clusters/upload` | POST (multipart) | Accepts YAML/JSON files, returns `{cluster_id, name}` |
| `/clusters/local/analysis/latest` | GET | schema_version 3.4.0; 82 non-admins, 3 single escalations |
| `/dashboard` | GET | 307 redirect (Next.js static export) |

## Test Results

### Smoke Tests (5/5 pass)

```
ok 1 AFM namespace exists and has a running pod
ok 2 AFM /health returns 200
ok 3 AFM /dashboard/ returns HTML
ok 4 AFM /clusters responds (sample data loaded)
ok 5 D2 kustomization builds cleanly
```

### Converter Tests (12/12 pass)

```
ok 1  converter produces valid JSON with required top-level keys
ok 2  every converted role has name, scope, and rules
ok 3  every converted binding has name, scope, roleRef, and subjects
ok 4  every converted subject has name and kind
ok 5  converter produces non-trivial output from the raw fixture
ok 6  converter deduplicates subjects across multiple bindings
ok 7  AFM fixture has the same contract shape as converter output
ok 8  AFM fixture contains fe-signalloom namespace roles
ok 9  afm-rbac-reader grants get and list on all four RBAC resource types
ok 10 afm-rbac-reader grants get and list on namespaces and serviceaccounts
ok 11 afm-rbac-reader does not grant write verbs
ok 12 kustomize build includes the cluster-import CronJob
```

### Live Integration Tests (7/7 pass)

```
ok 1 cluster-import CronJob can be triggered and succeeds
ok 2 cluster-import collected a non-trivial number of RBAC items
ok 3 imported local cluster has fe-signalloom, inf-signalloom, and inf-bao namespaces
ok 4 imported local cluster has non-trivial subjects, roles, and bindings
ok 5 escalation analysis finds non-admin escalation paths
ok 6 RBAC graph has nodes and edges for the local cluster
ok 7 conformance report is available for the local cluster
```

## Pipeline Flow (verified end-to-end)

1. CronJob `afm-cluster-import` runs every 30 minutes, collects live RBAC from the KiND cluster
2. Imported data lands as cluster `local` with namespaces including `fe-signalloom`, `inf-signalloom`, `inf-bao`
3. Escalation analysis (Z3 BMC engine) identifies 3 privilege-escalation paths across 82 non-admin subjects
4. RBAC graph and conformance report available via API
5. Dashboard served at `/dashboard` (Next.js static export)
6. Sample clusters (prod, demo, sample1, usage_sample) pre-seeded at deploy time

## Notes

- Port-forward already active on `18000:8000` (from deploy script or CronJob)
- The `/clusters/upload` endpoint expects multipart file upload, not raw JSON body
- The `.kind/kubeconfig` was missing; regenerated from `kind get kubeconfig --name osramp`
