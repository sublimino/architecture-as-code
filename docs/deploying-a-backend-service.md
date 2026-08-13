# Deploying a new backend service

Companion to [`cluster-debugging.md`](cluster-debugging.md). That file catalogues
probes that report a confident answer they have not earned; this one covers the
sibling failure — a service that is *complete and never deployed*, where every
layer between the browser and the code fails in a way that names something other
than the cause.

Twice in two days a finished backend slice sat in this repo and was never
deployed, and in both cases the first human to notice got a message that pointed
at the wrong thing:

- **fleet-manager** — Go source, tests and full manifests since 2026-08-04. No
  build target, in no kustomization, no nginx proxy. The Fleet page died on
  `Unexpected token '<', "<!doctype "... is not valid JSON`, because nginx's SPA
  catch-all answered the API call with `index.html` at **200 OK**. Wired up in
  `a430fe8`, which is the worked example below.
- **afm-platform** (KubeSec-AFM) — `d2-signalloom/apps/fe-signalloom/src/rbac_correlation.py:73`
  has pointed at `afm-platform.fe-k8s-afm.svc.cluster.local:8000` since the RBAC
  Explorer was wired against a live cluster on 2026-08-02. Nothing deploys that
  service unless you opt in with `make demo-k8s-afm-up`, so on a cluster where
  nobody had, `/rbac-explorer` answered with a 503 whose body was
  `KubeSec-AFM is unreachable: [Errno -2] Name or service not known`.

The 503 is the better of the two — `rbac_correlation.py` fails visibly and by
design, and says the words "KubeSec-AFM is unreachable". It still describes a DNS
result rather than the fact a human needs, which is *that slice was never
deployed, run `make demo-k8s-afm-up`*.

## Four layers, each of which alone breaks the page

Do not treat these as steps in a pipeline where the first failure masks the rest.
They are independent, and fixing one reveals the next. On fleet-manager, fixing
DNS produced an immediate 504 from layers 3 and 4.

**1. The service is actually deployed.** It needs a target that builds the image,
loads it into kind, and applies the manifests — and something has to *call* that
target. fleet-manager's manifests were correct and complete for eight days while
appearing in no kustomization and no `make` recipe, so nothing ever applied them.
Use `scripts/kind-load-verified.sh` rather than a bare `kind load docker-image`:
on a Docker daemon using the containerd image store, `kind load` can print
"loading…", exit 0, and transfer nothing, after which the pod goes
`ImagePullBackOff` against Docker Hub and the error names an HTML media type, not
your image.

**2. nginx proxies the browser-facing path.** With no `location` block, the
request falls through to `location /` and `try_files` serves `index.html` with
**200 OK**. `res.ok` is true, so a `fetch` goes straight to `res.json()` and
throws a parse error about a doctype. Two constraints on the prefix you pick: it
must not shadow a client-side route (nginx matches proxy locations before
`location /` reaches `try_files`, which is why the SuperCred proxy is
`/supercred-api/` and not `/supercred/`), and it usually needs a `rewrite` onto
the service's real mount — `/fleet-api` → `/api`, because the Go server registers
`/api/v1/fleet/topology` while the client calls `/fleet-api/v1/fleet/topology`.

**3. The receiver's NetworkPolicy admits the caller's actual labels.** Not the
labels you assume it has. fleet-manager's ingress admitted
`app.kubernetes.io/part-of: signalloom`; the dashboard pods carry only
`app.kubernetes.io/name: dashboard-signalloom`. A NetworkPolicy naming a label
the sender does not have is a closed door wearing a timeout's clothes — the
symptom is a 504 against a service that is healthy, listening, and correct.
Check the pod, not the manifest you remember:
`kubectl -n <ns> get pod <caller> --show-labels`.

**4. The caller's egress policy allows the destination.** The dashboard's
`allow-dashboard-egress` rule is per-destination; adding an nginx upstream
without adding the matching egress entry produces the same 504 as layer 3, from
the other end. This is the one layer the repo already guards: the
`every nginx upstream has a matching dashboard egress rule` test in
`d2-signalloom/test/dashboard-route-collisions.bats` went red the moment the
`/fleet-api/` proxy was added, which is exactly what it is for.

Note that the guard covers the **dashboard's nginx** only. A server-side caller —
the FastAPI backend reaching AFM over `httpx`, for example — takes its egress
from `allow-portal-dependencies` (selected by `bao.controlplane.io/consumer:
fe-signalloom`, not by app name), and no test asserts that rule exists. Layer 1
has no guard at all: nothing in CI fails because a service is undeployed.

## Two traps that are silent by construction

**`kubectl apply -k` puts namespace-less manifests in `default`.** Kustomize does
not infer a namespace. If neither the manifests nor `kustomization.yaml` names
one, the Deployment and Service land in `default`, where
`fleet-manager.fe-signalloom.svc.cluster.local` does not resolve and the proxy
cannot reach them. Nothing errors — `kubectl apply -k` reports success and the
pod runs. Pin it once in the kustomization (`namespace: fe-signalloom`, as
fleet-manager now does) or declare it on every object (as `afm-platform` does,
shipping its own `namespace.yaml`).

**A RoleBinding to a ServiceAccount that does not exist is legal and silent.**
The API server does not validate that the subject exists; it is a forward
reference by design. fleet-manager's binding named `namespace: default` for a SA
living in `fe-signalloom`, so it bound nothing and every pod `list`/`patch`
403'd. The sting is what happens next: **client-go surfaces a Forbidden list as
an empty result, not an error.** The Fleet page would have rendered an empty
fleet with no reason given — no 500, no log line, no red anything. Verify the
subject namespace matches where the Deployment actually runs, and prove the grant
resolves:

```bash
kubectl auth can-i list pods \
  --as=system:serviceaccount:fe-signalloom:fleet-manager -n fe-signalloom-agents
```

## The checklist

1. **Build and load, verifiably.** A `demo-<slice>-<svc>-image` target that runs
   `docker build` then `scripts/kind-load-verified.sh`.
2. **Apply and wait.** A `demo-<slice>-<svc>-up` target depending on the image
   target, then `kubectl apply -k …` and `kubectl rollout status` (or
   `wait_rollout` from `scripts/lib/wait.sh` — never `kubectl wait
   --for=condition=ready` on a Deployment; Deployments have no `Ready` condition).
   A matching `-down` target that deletes only this service.
3. **Pin the namespace** in `kustomization.yaml`, or declare it on every object.
4. **Check the RoleBinding subject namespace** against where the pod runs, and
   confirm with `kubectl auth can-i --as=system:serviceaccount:…`.
5. **Add the nginx `location`**, with a prefix that shadows no SPA route and a
   `rewrite` onto the server's real mount. Raise `proxy_read_timeout` if the
   endpoint is long-running; forward `Authorization` if it is gated server-side.
6. **Open the receiver's ingress** to the caller's real pod labels.
7. **Open the caller's egress** to the receiver's port.
8. **Make the client say what is wrong.** Check `content-type` before parsing: a
   200 that is not JSON is not an answer from your API. `fleetApi.ts` raises
   `FleetUnreachableError` naming both the cause and the remedy — "the
   fleet-manager service is not deployed or `/fleet-api/` is not proxied. Run
   `make demo-signalloom-fleet-up`."
9. **Run the guard**: `bats d2-signalloom/test/dashboard-route-collisions.bats`.
10. **Prove it end to end** through the same path the browser uses, not against a
    port-forward to the service:

```bash
kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
  curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  http://localhost:8080/fleet-api/v1/fleet/topology
```

`200 application/json` is a pass. `200 text/html` means layer 2 — nginx answered
with the SPA. `504` means layer 3 or 4. A DNS failure means layer 1.

## Worked example — `git show a430fe8`

The Fleet Manager wiring commit, and the shape to copy. Four gaps, one commit,
each fixed at its own layer:

| Layer | Gap | Fix in `a430fe8` |
|---|---|---|
| 1 | No build target; in no kustomization | `demo-signalloom-fleet-{image,up,down}` in `Makefile`, applied directly rather than through Flux |
| 1 | Manifests would land in `default` | `namespace: fe-signalloom` in `apps/fleet-manager/base/kustomization.yaml` |
| 1 | RoleBinding subject named `default` | subject `namespace: fe-signalloom` in `apps/fleet-manager/base/rbac.yaml` |
| 2 | No `/fleet-api/` location | `location /fleet-api/` in `apps/dashboard-signalloom/nginx.conf`, rewriting to `/api` |
| 3 | Ingress admitted `part-of` only | second `podSelector` for `app.kubernetes.io/name: dashboard-signalloom` in `apps/fleet-manager/base/networkpolicy.yaml` |
| 4 | No dashboard egress for 8082 | rule in `apps/fe-signalloom/base/networkpolicy.yaml` |
| — | Client parsed the SPA fallback | `content-type` check + `FleetUnreachableError` in `src/api/fleetApi.ts`, five tests |

## The AFM variant — only layer 1 missing

Worth studying because it is the *asymmetric* case, and it is why "the page is
broken" is never enough information to locate the fault.

The dashboard's nginx already proxies seven prefixes to
`afm-platform.fe-k8s-afm.svc.cluster.local:8000` (`/dashboard/`, `/afm/`,
`/clusters`, `/metrics/`, `/health`, `/jobs`, `/webhooks/`); `allow-dashboard-egress`
already permits `fe-k8s-afm:8000`; `allow-portal-dependencies` already permits
the FastAPI backend's server-side `httpx` call; and `afm-platform` has no ingress
NetworkPolicy of its own, so layer 3 is vacuously satisfied. Layers 2, 3 and 4
were all in place. Only layer 1 was missing, and that alone was enough.

Two durable properties of this slice, independent of whether it happens to be
running right now:

- **It is opt-in.** Neither `make up` nor `make demo-signalloom-up` deploys it.
  `make demo-k8s-afm-up` does, via `scripts/k8s-afm.sh up`, and any dashboard
  page backed by AFM is broken until someone runs it.
- **Its image is not built from this repo.** `scripts/k8s-afm.sh` builds from
  `$KUBESEC_AFM_ROOT`, defaulting to `/home/andy/src/cp/kubesec-afm`. On a
  machine without that checkout the build fails, and no amount of reading
  `d2-k8s-afm/` explains why.

## The rule

Deployment is part of the feature. A slice with source, tests and manifests but
no path from `make` to a running pod is not done — it is a slice that will be
discovered by whoever opens the page, via an error naming a doctype, a DNS
result, or a timeout. If you cannot name the target that deploys your service and
the command that proves it answers through nginx, you have not finished.
