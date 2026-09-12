# SLON-P3 — docs-signalloom Portal Provenance and Gap Analysis

**Produced by:** `SLON-P3-PRE` preflight, 2026-09-10 11:49:56+01:00
**Base ref under test:** `refs/heads/integration/slon-v0.1.0` @ `a69cbba7a1255a4b95668c2859b62241d39c003b`
**Companion to:** [`slon-p3-preflight-proof.md`](slon-p3-preflight-proof.md)

This document answers one question precisely: *where does the Signal Loom documentation portal
actually live, what does it contain, and what exactly is missing from the branch Phase 3 must
build on.*

---

## 1. Provenance

| Fact | Value |
| --- | --- |
| Common ancestor of the two branches | `47359d5261fcb74399561c3eaa2d9f87ba2881a1` — *test: migrate BATS test suites to wait_job helper*, 2026-09-09 16:29:56 +0100 |
| Portal present at the common ancestor? | **No.** `git cat-file -e 47359d52:…/docs-signalloom/package.json` → absent |
| Commit that introduced the portal | `56e35ea57ef0ac34add59cba7f9a83eef5dde8a7` — *test: harden KPAI, CPAI, Kagent, and acceptance test harnesses*, 2026-09-10 09:41:28 +0100 |
| Branch carrying it | `feat/signal-loop-and-bootstrap-refactor` @ `3579e79b3e98a8e1abfc1b8c050ba06ca46bdb07` |
| Integration branch tip | `a69cbba7a1255a4b95668c2859b62241d39c003b` |
| Divergence (`--left-right --count`) | `36  4` — integration is 36 ahead, 4 behind |
| Ancestry either way | none — `merge-base --is-ancestor` returns `rc=1` in both directions |

Two earlier objects (`c76d9527`, `37b7da6c`, both 2026-09-09 16:33) also carry the portal, but
they are `git stash` *untracked-files* entries reachable only from `rescue-*` refs — the portal
was authored as untracked files, stashed, and later committed properly at `56e35ea5`.

## 2. What exists on `feat/signal-loop-and-bootstrap-refactor`

29 tracked files under `d2-signalloom/apps/docs-signalloom/`, plus its platform wiring.

### 2.1 Application

```
astro.config.mjs           base: "/docs", site from DOCS_SITE_URL,
                           default https://dashboard.osramp.acme.local
package.json               astro 7.2.10 · @astrojs/starlight 0.42.0 ·
                           @astrojs/check 0.9.4 · mermaid 11.17.2 · typescript 5.7.3
                           scripts: build = "astro check && astro build"
package-lock.json          npm lockfile (273 KB) — note: npm, not bun
tsconfig.json
Dockerfile                 node:22-alpine (digest-pinned) → npm ci → npm run build
                           → cgr.dev/chainguard/nginx (digest-pinned)
                           requires build arg SOURCE_ID (RUN test -n "$SOURCE_ID")
                           dist → /usr/share/nginx/html/docs
nginx.conf                 /readyz health endpoint; 308 redirect / → /docs/;
                           try_files … =404 fail-closed
src/components/Mermaid.astro
src/content.config.ts
src/styles/custom.css
.astro/…                   5 generated type/collection files, committed
```

### 2.2 Content — 14 built routes

| Sidebar group | Pages |
| --- | --- |
| Start here | `index.mdx` · `start/quick-start.md` · `start/first-agent.md` · `start/external-linux-agent.mdx` |
| Operate agents | `operate/stun-agent.mdx` |
| Run demonstrations | `demos/superadmin.md` |
| Use the platform | `roles/view-only.md` · `roles/advanced.md` · `roles/security-team.md` · `roles/platform-admin.md` |
| Reference | `reference/roadmap.md` · `reference/glossary.md` · `reference/documentation-rules.md` |

Plus the generated `404`, which currently emits a build warning
(`/404.htmlEntry docs → 404 was not found.`).

### 2.3 Platform wiring

| File | Role |
| --- | --- |
| `fe-signalloom/base/docs-deployment.yaml` | Deployment `docs-signalloom`; image `${IMAGE_BASE}/signalloom/apps/docs-signalloom:${ARTIFACT_TAG}`; `automountServiceAccountToken: false`; `readOnlyRootFilesystem: true`; `allowPrivilegeEscalation: false`; readiness probe `/readyz`; `emptyDir.sizeLimit: 16Mi` |
| `fe-signalloom/base/docs-service.yaml` | ClusterIP `docs-signalloom`, port 8080, selector `app.kubernetes.io/name=docs-signalloom` |
| `fe-signalloom/base/gateway-route.yaml` | `HTTPRoute signalloom-docs`, host `dashboard.${CLUSTER_DOMAIN}`, `PathPrefix: /docs`, backend `docs-signalloom:8080`, **no filters** (prefix is not rewritten — the app owns `/docs` via Astro `base`) |
| `fe-signalloom/base/networkpolicy.yaml` | `allow-docs-gateway-ingress` — Ingress-only, port 8080, from `namespaceSelector kubernetes.io/metadata.name=ingress` |
| `.github/workflows/…` | publishes workload `docs-signalloom` with `SOURCE_ID=${{ steps.source.outputs.source_id }}` |
| `d2-signalloom/test/docs-platform.bats` | 9 structural tests asserting every contract above |

### 2.4 The existing BATS contract

`docs-platform.bats` is the acceptance surface Phase 3 should be measured against. Its tests:

1. Docs build uses Astro Starlight at the docs base path — `base: "/docs"`, `@astrojs/starlight`, Dockerfile `dist` copy path, digest-pinned Chainguard nginx.
2. Docs nginx serves health and fail-closed static routes — `location = /readyz`, `return 308 /docs/;`, `try_files $uri $uri/ $uri/index.html =404;`.
3. Docs Deployment uses the signed image and hardened runtime — the full `yq` invariant above.
4. Docs source identity covers its build context — `source_id_for docs-signalloom` matches `^[0-9a-f]{64}$`.
5. Docs publishing passes the source identity build argument — workflow carries `workload: docs-signalloom` and `SOURCE_ID=…`.
6. Docs Service selects the docs workload on port 8080.
7. Docs HTTPRoute owns the docs prefix without rewriting it — asserts `filters` length is 0.
8. Docs NetworkPolicy allows only Gateway ingress.
9. Docs content covers the requested user journeys.

**All nine are static** — they read files with `grep` and `yq`. None needs a cluster. They can
therefore gate the remediation merge directly.

## 3. What is missing from `integration/slon-v0.1.0`

Verified with `git cat-file -e` against the ref (a probe a sandbox cannot silently blank):

| Path | Status on integration ref |
| --- | --- |
| `d2-signalloom/apps/docs-signalloom/package.json` | **ABSENT** |
| `d2-signalloom/apps/docs-signalloom/astro.config.mjs` | **ABSENT** |
| `d2-signalloom/apps/fe-signalloom/base/docs-service.yaml` | **ABSENT** |
| `d2-signalloom/apps/fe-signalloom/base/docs-deployment.yaml` | **ABSENT** |
| `d2-signalloom/test/docs-platform.bats` | **ABSENT** |
| `signalloom-docs` rule in `gateway-route.yaml` | **ABSENT** — the file exists and declares only `/` → `dashboard-signalloom`, `/dex` → `dex`, `/api` → `fe-signalloom-api` |
| `allow-docs-gateway-ingress` in `networkpolicy.yaml` | **ABSENT** |
| Tracked files under `d2-signalloom/apps/docs-signalloom/` | **0** (`git ls-files` → `count=0`) |

### 3.1 The one thing that *is* there, and why it misleads

`d2-signalloom/apps/docs-signalloom/` exists as a directory in the worktree and contains exactly
one entry:

```
node_modules -> /home/andy/src/cp/osramp-demo/d2-signalloom/apps/docs-signalloom/node_modules
```

An untracked symlink into the **main checkout**, whose target does resolve. A casual `ls` of the
apps directory therefore lists `docs-signalloom` alongside every real app, and a casual
`test -d` passes. Only `git ls-files` distinguishes "tracked on this ref" from "a stray symlink
someone's tooling left behind". Any Phase 3 agent that checks for the portal with a directory
test will conclude it is present.

## 4. Cluster state versus branch state

| Object | Age | Source |
| --- | --- | --- |
| `fe-signalloom/docs-signalloom` Deployment `1/1` | 18h | OCI artifact |
| `fe-signalloom/docs-signalloom` Service `ClusterIP:8080` | 18h | OCI artifact |
| `fe-signalloom/signalloom-docs` HTTPRoute | 18h | OCI artifact |
| Image | — | `zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/docs-signalloom:latest` |

Live HTTP through the gateway NodePort (`--resolve dashboard.osramp.acme.local:31436:172.18.0.5`):

```
GET /docs/  -> 200
GET /docs   -> 308     (nginx redirect, as the BATS contract requires)
GET /       -> 200
```

**Every Flux source in this cluster is an `OCIRepository`.** `kubectl get gitrepository -A`
returns nothing; the `custom-columns` query for `.spec.ref.branch` produced an empty table. There
is no git revision anywhere in cluster state, so the cluster cannot attest which branch it was
built from. What it *can* attest: the manifests it is running exist only on
`feat/signal-loop-and-bootstrap-refactor`. The portal was published from that tree via
`push-local.sh`-style local publication, 18 hours before this preflight.

**Operational consequence.** For the whole of Phase 3, a live probe of `/docs` is not evidence
about `integration/slon-v0.1.0` and must not be used as one. The static
`docs-platform.bats` suite, run against the checked-out tree, is the correct instrument. This is
the same failure mode that let `SLON-P1-PRE` record `/docs/ -> 200 OK` as a property of the
integration line when it was a property of a different branch.

## 5. Gap-closure scope

Minimum set to make Phase 3 executable on the integration branch:

```
d2-signalloom/apps/docs-signalloom/**                      (29 files)
d2-signalloom/apps/fe-signalloom/base/docs-service.yaml
d2-signalloom/apps/fe-signalloom/base/docs-deployment.yaml
d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml   (add signalloom-docs rule only)
d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml   (add allow-docs-gateway-ingress only)
d2-signalloom/test/docs-platform.bats
.github/workflows/…                                        (add docs-signalloom workload entry)
```

Everything else in the four unmerged commits is out of scope for closing this gap, and some of it
is actively hazardous to merge: `dashboard-signalloom/src/components/onboarding`,
`dashboard-signalloom/src/api` and `dashboard-signalloom/src/auth` are the same files
`SLON-P1-1`, `SLON-P1-2` and `SLON-P1-3` already changed on the integration line.

Acceptance for the closure, all offline:

```
bats d2-signalloom/test/docs-platform.bats                        # expect 9/9
ASTRO_TELEMETRY_DISABLED=1 bun run --cwd …/docs-signalloom build  # expect rc=0, 14 pages
```
