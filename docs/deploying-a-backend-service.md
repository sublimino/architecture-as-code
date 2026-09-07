# Deploying a New Backend Service

This document complements [`cluster-debugging.md`](cluster-debugging.md).
That document covers false-positive diagnostic probes.
This document covers services that are fully coded but never deployed.
In these cases, intermediate network and routing layers report misleading errors.

Two backend services encountered this failure pattern:

- **fleet-manager**: Source code, tests, and Kubernetes manifests existed since 2026-08-04.
  The service lacked a build target, Flux inclusion, and an nginx proxy rule.
  The Fleet UI page failed with `Unexpected token '<', "<!doctype "... is not valid JSON`.
  The nginx SPA fallback returned `index.html` with HTTP status **200 OK**.
  Commit `a430fe8` resolved this defect.
- **afm-platform** (KubeSec-AFM): The backend router `d2-signalloom/apps/fe-signalloom/src/rbac_correlation.py`
  calls `afm-platform.fe-k8s-afm.svc.cluster.local:8000`.
  The platform deploys this service only when an operator runs `make demo-k8s-afm-up`.
  Without this step, `/rbac-explorer` returned HTTP 503 with error:
  `KubeSec-AFM is unreachable: [Errno -2] Name or service not known`.

The HTTP 503 response clearly states unreachable status.
However, it describes DNS resolution rather than the operational root cause:
the operator did not deploy the slice via `make demo-k8s-afm-up`.

## Four Independent Layers

Do not treat these layers as a linear pipeline where one failure masks another.
These layers operate independently. Resolving one layer reveals faults in subsequent layers.
For fleet-manager, fixing DNS immediately revealed HTTP 504 errors in layers 3 and 4.

**1. Service Deployment**:
Provide targets to build the container image, load it into Kind, and apply Kubernetes manifests.
Execute these targets systematically.
Use `scripts/kind-load-verified.sh` instead of bare `kind load docker-image`.
With containerd storage, `kind load` can exit 0 without transferring data,
causing `ImagePullBackOff` errors against public registries.

**2. Reverse Proxy Routing (nginx)**:
Configure explicit `location` blocks for backend paths in nginx.
Without a matching `location`, nginx falls back to `location /` and serves `index.html` with status **200 OK**.
Client code evaluates `res.ok` as true and fails when parsing HTML as JSON.
Ensure your path prefix does not conflict with client-side SPA routes.
Rewrite external paths to match server mounts (for example, rewrite `/fleet-api` to `/api`).

**3. Ingress NetworkPolicy**:
Configure the receiver's NetworkPolicy to accept the caller's actual pod labels.
Inspect running pod labels directly:
`kubectl -n <ns> get pod <caller> --show-labels`.
If the policy specifies mismatched labels, requests drop silently and return HTTP 504 gateway timeouts.

**4. Egress NetworkPolicy**:
Configure the caller's NetworkPolicy to allow outbound traffic to the destination service port.
The dashboard egress policy `allow-dashboard-egress` restricts destinations per port and namespace.
Adding an upstream target without an egress rule causes HTTP 504 timeouts.
Test route collisions with:
`bats d2-signalloom/test/dashboard-route-collisions.bats`.

Note: This automated test covers the dashboard nginx proxy only.
Server-side callers (such as FastAPI calling AFM via `httpx`) rely on `allow-portal-dependencies`.
CI test suites do not check for missing service deployments.

## Two Silent Configuration Pitfalls

**Manifests Without Namespaces Default to `default`**:
Kustomize does not infer namespaces automatically.
If manifests omit namespaces, resources deploy to the `default` namespace.
Internal cluster DNS names will not resolve, and reverse proxies cannot connect.
Declare namespaces explicitly in `kustomization.yaml` or in every resource manifest.

**RoleBindings Allow Non-Existent ServiceAccounts**:
The Kubernetes API server accepts RoleBindings that reference non-existent ServiceAccounts.
If a binding targets a ServiceAccount in the wrong namespace, authorization fails silently.
In client-go, unauthorized `list` operations return empty collections without raising errors.
The dashboard then renders empty tables without reporting failures.
Verify that the ServiceAccount exists in the target namespace and test permissions:

```bash
kubectl auth can-i list pods \
  --as=system:serviceaccount:fe-signalloom:fleet-manager -n fe-signalloom-agents
```

## Deployment Checklist

Follow this checklist for every new backend service:

1. **Build and Load**: Create a `demo-<slice>-<svc>-image` target using `scripts/kind-load-verified.sh`.
2. **Apply and Wait**: Create a `demo-<slice>-<svc>-up` target that applies manifests and waits for rollout.
   Use `wait_rollout` from `scripts/lib/wait.sh`.
   Do not use `kubectl wait --for=condition=ready` on Deployments.
   Create a matching `-down` target that removes the service.
3. **Set Namespaces**: Pin namespaces in `kustomization.yaml` or declare them in each manifest.
4. **Verify RBAC**: Confirm ServiceAccount namespaces and test permissions with `kubectl auth can-i`.
5. **Configure Proxy**: Add nginx `location` blocks with route rewrites and appropriate timeouts.
6. **Set Ingress Policy**: Grant network ingress to the caller's pod labels.
7. **Set Egress Policy**: Grant network egress to the receiver's service port.
8. **Add Error Handling**: Validate the response `content-type` header before parsing JSON bodies.
   Raise explicit errors when responses return HTML or unexpected content types.
9. **Run Route Guards**: Run `bats d2-signalloom/test/dashboard-route-collisions.bats`.
10. **Test End-to-End**: Test connectivity through the reverse proxy from inside the dashboard container:

```bash
kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
  curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  http://localhost:8080/fleet-api/v1/fleet/topology
```

Interpret test results:
- `200 application/json`: The service functions correctly.
- `200 text/html`: Reverse proxy missing; nginx returned the SPA HTML.
- `504`: NetworkPolicy blocked ingress or egress traffic.
- DNS failure: The target service is not deployed.

## Implementation Example: `git show a430fe8`

Commit `a430fe8` wired Fleet Manager across all four layers:

| Layer | Issue | Solution in `a430fe8` |
|---|---|---|
| 1 | No build or deployment targets | Added `demo-signalloom-fleet-{image,up,down}` to Makefile |
| 1 | Manifests lacked namespace | Added `namespace: fe-signalloom` to `apps/fleet-manager/base/kustomization.yaml` |
| 1 | RoleBinding targeted `default` namespace | Updated subject namespace to `fe-signalloom` in `apps/fleet-manager/base/rbac.yaml` |
| 2 | Missing proxy location | Added `/fleet-api/` proxy and rewrite rule to `nginx.conf` |
| 3 | Ingress restricted by `part-of` label | Added `dashboard-signalloom` selector to `networkpolicy.yaml` |
| 4 | Dashboard egress lacked port 8082 | Added egress rule to `apps/fe-signalloom/base/networkpolicy.yaml` |
| Client | Client parsed HTML fallback | Added `content-type` validation and `FleetUnreachableError` to `fleetApi.ts` |

## AFM Integration Pattern

The AFM platform illustrates an asymmetric integration failure.
The dashboard proxy routes seven endpoints to `afm-platform.fe-k8s-afm.svc.cluster.local:8000`.
Egress rules permit dashboard and FastAPI traffic to port 8000.
The AFM service has no ingress NetworkPolicy restrictions.
Layers 2, 3, and 4 operated correctly, but layer 1 was absent.

Remember these operational characteristics:
- **Deployment is opt-in**: Run `make demo-k8s-afm-up` before accessing AFM dashboard pages.
- **External repository build**: `scripts/k8s-afm.sh` builds images from `$KUBESEC_AFM_ROOT`.
  Ensure this environment variable points to a valid checkout.

## Deployment Rule

Deployment integration forms an essential part of every feature.
A codebase with source files and manifests is incomplete without automated deployment targets.
Always define the deployment target and verify connectivity through the reverse proxy.
