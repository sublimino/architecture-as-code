# Dashboard: superadmin mode, themes, and the RBAC importer

Three additions to the Signal Loom dashboard SPA (`d2-signalloom/apps/dashboard-signalloom`),
plus the SuperCred discovery fixes that shipped alongside them.

- [Superadmin visibility mode](#superadmin-visibility-mode)
- [Theme switcher](#theme-switcher)
- [RBAC importer](#rbac-importer)
- [SuperCred agent discovery](#supercred-agent-discovery)

---

## Superadmin visibility mode

A toggle in the sidebar footer, directly below **Help & Support**, that shows or hides the five
deep-technical navigation entries. It exists so a customer-facing walkthrough can start on the
governance surface and reveal the security internals on demand.

**Gated behind superadmin:** Cryptography, Federated Services, Collusion & Access, RBAC Analysis,
RBAC Explorer.
**Always visible:** Agents, Compliance, Audit Trail, SuperCred, Settings.

### This is visibility, not authorization

Every route stays registered in `App.tsx` and remains reachable by direct URL whether superadmin is
on or off. Hiding a nav link is a demo affordance. It is not a security control and must never be
described as one — when RBAC lands, authorization belongs at the route guard and the API, not here.

### Who sees the toggle

Only the demo user. The predicate lives in `src/auth/superadmin.ts`:

```ts
isSuperadminEligible(user)   // email === 'demo-user@signalloom.local'
                             //   || preferred_username === 'demo-user'
                             //   || name === 'demo-user'
```

Three claim shapes are matched because Dex populates them inconsistently across flows.

**This is a temporary stand-in.** There is no user-authentication table and no RBAC model yet. When
one exists, replace the body of `isSuperadminEligible()` with the role lookup — that function is the
single place that has to change.

The identity gate beats the stored preference: a stale `signalloom.superadmin=true` in localStorage
for a non-eligible user reveals nothing and renders no toggle.

### State

| | |
|---|---|
| Storage key | `signalloom.superadmin` (localStorage) |
| Default | off |
| Context | `superadmin` / `setSuperadmin` on `AppContext` |
| Nav flag | `superadminOnly: true` on entries in the `NAV` array in `Sidebar.tsx` |

Adding a page to the gated set means adding `superadminOnly: true` to its `NAV` entry. Nothing else.

| File | Role |
|------|------|
| `src/auth/superadmin.ts` | eligibility predicate, storage, `useSuperadmin()` hook |
| `src/components/Sidebar.tsx` | toggle UI, `NAV` filtering |
| `src/App.tsx` | context wiring |
| `src/auth/superadmin.test.ts`, `src/components/Sidebar.test.tsx` | tests |

---

## Theme switcher

A dropdown pinned to the bottom-right of the viewport, immediately left of the demo/live toggle.
Three themes: **Dark** (default), **Light**, **Andy** (red on black).

Selection applies instantly — no reload, no network call of any kind — and persists in localStorage
under `signalloom.theme`. An unknown stored value falls back to Dark.

### How a theme is defined

`src/styles/themes.ts` is the single source of truth. A theme is a complete map of the fourteen CSS
custom properties declared in `global.css`'s `:root` block:

```
--bg  --surface  --surface2  --border  --border-subtle  --cyan  --violet
--teal  --amber  --error  --text  --muted  --slate-gray  --warning
```

Every theme must supply a value for **all fourteen** — no theme inherits another's values. That is
what lets a future theme restyle the whole sheet rather than swapping an accent, and it is enforced
by a test that iterates the key set.

`applyTheme(name)` sets `data-theme="<name>"` on `document.documentElement` and writes the variable
values as inline custom properties, which outrank the `:root` block.

### Adding a fourth theme

Edit `src/styles/themes.ts` only: extend the `ThemeName` union, add a label to `THEME_LABELS`, add
the full variable map to `THEMES`. No component code changes.

### Dark is regression-guarded

Dark reproduces the shipped palette byte-for-byte. `themes.test.ts` asserts its map against the
literal values in `global.css`, so changing one without the other fails the suite.

### Known limit

The theme reaches anything driven by the CSS variables. Components that take colours from literals
in `src/styles/tokens.ts` do not follow it. The agent donut and the status pills were fixed to read
from variables because they were illegible under Light; the remaining literals are still literal. A
full token-to-variable migration is deliberately out of scope.

| File | Role |
|------|------|
| `src/styles/themes.ts` | theme definitions, `applyTheme`, storage helpers |
| `src/components/ThemeToggle.tsx` | the dropdown |
| `src/styles/themes.test.ts`, `src/components/ThemeToggle.test.tsx` | tests |
| `src/components/StatusBadge.tsx`, `src/pages/AgentsPage.tsx` | legibility fixes |

---

## RBAC importer

A panel at the top of `/rbac-analysis`, above the embedded KubeSec-AFM dashboard. It fetches a
cluster's RBAC from AFM, filters it to a namespace, renders AFM-import YAML, and offers a **Copy**
button. Paste the result into AFM's cluster upload to start a graph walk.

### Flow

1. On mount: `GET /afm/clusters` populates the cluster select (prefers id `local`, else the first).
2. `GET /afm/clusters/{id}/rbac` populates the namespace select — "All namespaces" plus the sorted
   distinct namespaces found in the payload.
3. **Generate YAML** converts the payload to the AFM import object and serialises it.
4. **Copy** writes the textarea to the clipboard, with a graceful fallback where
   `navigator.clipboard` is unavailable.

### It is read-only

The importer never POSTs to AFM and never mutates AFM state. Getting data *into* AFM is the
CronJob's job (below) or a manual paste. This constraint is covered by a test asserting every fetch
call is a GET.

### Output contract

The emitted object matches `scripts/rbac-to-afm.py`:

```yaml
id: prod
name: Prod GitOps Cluster
rbac:
  subjects: [...]
  roles: [...]
  bindings: [...]
```

Cluster-scoped roles and bindings are retained under **every** namespace selection; namespace-scoped
items from other namespaces are dropped. Subjects referenced by a retained binding are kept even if
their own namespace differs.

### The YAML emitter is hand-rolled

`src/api/afmYaml.ts`, no dependency. Kubernetes RBAC is full of strings YAML will happily
misinterpret — `system:masters`, a bare `*` verb, resource names with trailing whitespace, values
that read as booleans (`yes`, `no`, `on`, `off`) or numbers. All are quoted and escaped, and the
test suite asserts a full emit-parse round-trip including a fixture where every string is awkward at
once.

### AFM sends `null`, not absent

AFM returns `"namespace": null` on cluster-scoped items rather than omitting the key, and
`"roleRefKind": null` on bindings. Validation treats an explicit `null` as absent; cluster-scoped
items emit **without** a `namespace` field. Fixtures are built from real captured payloads rather
than from the TypeScript interface — the first version of this code passed its tests and still
rejected every live response, because the fixtures were written to the type and the type had never
been checked against the wire.

### Three implementations of one contract

`src/api/afmYaml.ts`, `scripts/rbac-to-afm.py`, and the CronJob below all convert Kubernetes RBAC
into the AFM import shape. Divergence between them is a latent bug; see the notes in
`src/api/afmYaml.test.ts` before changing any of them.

| File | Role |
|------|------|
| `src/api/afmApi.ts` | AFM fetch helpers, payload validation, namespace derivation |
| `src/api/afmYaml.ts` | converter + YAML emitter |
| `src/components/RbacImporterPanel.tsx` | the panel |
| `src/api/afmYaml.test.ts`, `src/pages/RbacAnalysisPage.test.tsx` | tests |

### The AFM cluster-import CronJob

`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml` collects cluster RBAC every 30 minutes and
POSTs it to AFM. It previously sent the raw Kubernetes `List` shape, received HTTP 400, swallowed
the error in a `try/except` that only printed, and reported `Complete` — so it had been importing
nothing, silently. It now converts before POSTing and exits non-zero on a non-2xx, so a failure
shows up as a failed Job.

---

## SuperCred agent discovery

The SuperCred demo's **Refresh Agents** button appeared to do nothing. It was five separate defects
stacked, each masking the next. Three of them were a missing permission or a missing verification
that failed *silently* — which is why the symptom was "nothing happens" rather than an error.

### 1. Discovery searched the wrong namespace

`agents-cardvault.yaml` declares `namespace: fe-signalloom-agents`, but the `signalloom-apps`
Kustomization carries `targetNamespace: << inputs.tenant >>`, which relocates the pod into
`fe-signalloom`. The proxy hard-coded the former, so the correctly-labelled SuperCred agent was
invisible and the UI's `supercred === true` filter returned an empty list.

Discovery is now namespace-plural and env-configurable:

```
AGENT_DISCOVERY_NAMESPACES=fe-signalloom-agents,fe-signalloom   # default
```

`/agents` unions pods across the list, de-duplicates on `(namespace, name)`, returns each agent's
own `namespace`, and reports per-namespace failures in `namespace_errors` rather than failing whole.
`/agents/{id}/compliance` and `/agents/{id}/stun` resolve the namespace by lookup; an optional
`?namespace=` hint is honoured **only** if it appears in the configured list, so it cannot be used
to read pods outside the demo's tenancy.

### 2. The proxy had no permission to read that namespace

Multi-namespace discovery then hit `HTTP 403` on `fe-signalloom`. The proxy runs as the `default`
ServiceAccount in `inf-signalloom`, whose only grant was scoped to `fe-signalloom-agents`. A
mirrored least-privilege `Role` (`pods`: `get`, `list`, `watch`) and `RoleBinding` now exist in the
tenant namespace, declared together in the `signalloom-apps` ResourceSet in
`d2-osramp-fleet/tenants/local/signalloom.yaml`.

That narrow Role and the `?namespace=` allow-list are complementary: both would have to widen before
discovery could reach another tenant's pods.

### 3. `cardvault-agent:local` never reached the kind node

`kind load docker-image` printed `loading...`, exited 0, and transferred nothing. The manifest
landed in containerd's content store while the layers did not, so kubelet failed with
`unexpected media type text/html ... : not found` and the demo Job sat in `ImagePullBackOff`.

The trap: **`ctr -n k8s.io images ls` still lists such an image**, because the content store holds
the manifest. Any check built on `ctr images ls` passes while the image is unusable. `crictl images`
reports the CRI's view — unpacked and runnable — and is the only sound probe.

`make demo-signalloom-supercred-images` now runs `scripts/supercred-images.sh`, which builds with a
pinned platform, loads, **verifies via `crictl`**, recovers by rebuilding straight into a
docker-archive and importing that, and fails loudly if any image is still missing. Covered by
`test/supercred-images.bats`.

### 4. `/supercred` redirected off-origin

`GET /supercred` returned `301 Location: http://dashboard.osramp.acme.local:8080/supercred/` —
nginx builds absolute redirects from its **own** listen scheme and port, which do not exist outside
the cluster. A browser following it got `ERR_CONNECTION_REFUSED`. `absolute_redirect off` and
`port_in_redirect off` make redirects relative, so they stay on whatever origin the client used.

The redirect existed at all because the API proxy prefix `/supercred/` shadowed the `/supercred`
SPA route: nginx matches proxy locations before `location /` reaches `try_files`, so the React page
could never render. The proxy moved to `/supercred-api/`.

**Not** `/api/supercred/`, despite reading better — the gateway's `signalloom-api` HTTPRoute matches
`PathPrefix /api` and sends it to `fe-signalloom-api`, a longer prefix than the dashboard's `/`
route, so anything under `/api` never reaches this nginx at all. A distinct root-level prefix is the
only split that is unambiguous at both the gateway and nginx.

**Invariant: no nginx proxy prefix may shadow a client-side route registered in `App.tsx`.**
Enforced by `d2-signalloom/test/dashboard-route-collisions.bats`.

### 5. The dashboard had no egress permission to reach the proxy

With routing fixed, the page still hung on "Loading…". nginx logged `499` (client gave up while
waiting upstream) and the proxy logs were empty — the connection never arrived.
`NetworkPolicy/allow-dashboard-egress` permitted DNS, Dex on 5556, the API on 8000 and `fe-k8s-afm`
on 8000, but **not** port 8080 to `fake-integration-proxy`, and `default-deny` covers egress.

Easy to misread: `allow-portal-dependencies` does allow 8080 into `inf-signalloom`, but its
podSelector is `bao.controlplane.io/consumer: fe-signalloom` — the API pod, not the dashboard.

The egress rule on `allow-dashboard-egress` and the ingress rule on `allow-fake-integration-proxy`
are two halves of one path. Changing either alone breaks the page with no error anywhere except a
499 in an nginx access log.

### Running the demo

```bash
make demo-signalloom-supercred-images        # build + load + verify (safe to re-run)
make demo-signalloom-supercred-1             # deploy services, agent, OpenBao secrets, SPIRE entry
make demo-signalloom-supercred-2             # SPIFFE → OpenBao → cardvault credential chain
#   then in the UI: Refresh Agents → Compliance Scan → Stun Agent
make demo-signalloom-supercred-5             # teardown
make demo-signalloom-supercred-all           # steps 1→5
make demo-signalloom-supercred-images-test   # bats guard, no cluster required
```

---

## Verifying locally

```bash
cd d2-signalloom/apps/dashboard-signalloom
bunx tsc --noEmit
bunx eslint src/ --max-warnings 0
bunx vitest run

cd ../fake-integration-proxy
PYTHONPATH=. python3 -m unittest discover -s test    # NOT pytest — the suite is unittest

bats test/supercred-images.bats
bats d2-signalloom/test/dashboard-route-collisions.bats
bats d2-signalloom/test/agent-discovery-rbac.bats
```

**The branch carries pre-existing lint and type errors** unrelated to this work: one `tsc` error in
`RbacExplorerPage.tsx:253` and four eslint errors (two `rules-of-hooks` in `DemoToggle.tsx`, unused
vars in `RbacExplorerPage.tsx:167` and `SuperCredPage.tsx:102`). The bar for changes here is **no
new errors beyond that set**, not a clean exit.

### In the browser

```bash
kubectl -n ingress port-forward svc/envoy-ingress-cluster-<hash> 30754:443 --address 127.0.0.1
# → https://dashboard.osramp.acme.local:30754
#   demo-user@signalloom.local / demo-user
```

The port must be 30754 — the Dex issuer and redirect URI are pinned to it. There is no host
NodePort binding on this kind cluster; the port-forward is the access path.
