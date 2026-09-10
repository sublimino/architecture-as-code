# SLON-P3-PRE — Phase 3 Preflight Verification Proof

**Card:** `SLON-P3-PRE` — Preflight verification of docs-signalloom Astro build and documentation routes
**Depends on:** `SLON-P2-GOV`
**Base ref:** `refs/heads/integration/slon-v0.1.0`
**Worktree HEAD:** `a69cbba7a1255a4b95668c2859b62241d39c003b` (detached; identical to the integration branch tip)
**Tree hash:** `16cb7da73786f98acc845c4a253bd169e5638cf8`
**Executed:** 2026-09-10 11:49:56+01:00
**Verdict:** ❌ **FAIL — Phase 3 is NOT safe to start on this base ref.**

---

## 1. Verdict in one paragraph

The Astro Starlight documentation portal that every Phase 3 card is chartered to build on
**does not exist on `integration/slon-v0.1.0`**. Its entire source tree, its `Dockerfile`, its
Kubernetes `Service`/`Deployment`/`NetworkPolicy`, the `/docs` `HTTPRoute` rule and its BATS
suite live only on the divergent branch `feat/signal-loop-and-bootstrap-refactor`, in four
commits that were never merged into the integration line. The running `kind-osramp` cluster
*does* serve `/docs/` with HTTP 200, but it is reconciled from OCI artifacts published out of
that other branch — so the live 200 is evidence about `feat/signal-loop-and-bootstrap-refactor`,
not about the ref Phase 3 must work from. Two of this card's three "verified facts about the
repository" are therefore true of the wrong tree.

The framework itself is healthy: given the source, the portal builds cleanly under this
machine's toolchain (14 pages, exit 0). The declared hard blocker for this card — *"Astro
Starlight framework crash or incompatible Node.js runtime version"* — is **falsified**, and is
not the reason for this FAIL.

---

## 2. Card premises versus the base ref

| Card premise | Status on `integration/slon-v0.1.0` | Evidence |
| --- | --- | --- |
| "Documentation portal is powered by Astro Starlight" | ❌ **False on this ref** (true on `feat/signal-loop-and-bootstrap-refactor`) | `git ls-files -- d2-signalloom/apps/docs-signalloom` → `count=0`; no `astro`/`starlight` string anywhere in the tracked tree |
| "Docs route is exposed at `/docs`" | ❌ **False on this ref** (true in the live cluster and on the other branch) | `gateway-route.yaml` on this ref declares only `/`, `/dex`, `/api` — no `/docs` rule, no `docs-signalloom` backend |
| Certified Phase 2 integration baseline from `SLON-P2-GOV` is merged | ✅ True | `git merge-base --is-ancestor integration/slon-v0.1.0 HEAD` → `rc=0`; tip is `a69cbba7 docs(signalloom): record Phase 2 completion and Phase 3 roadmap in governor log` |

## 3. Required tests — actual results

All six of this card's Required Tests were executed verbatim from the worktree.

| # | Command | Result | Interpretation |
| --- | --- | --- | --- |
| 1 | `bun run --cwd d2-signalloom/apps/docs-signalloom build` | `error: Script not found "build"` — **rc=1** | No `package.json` on this ref. The directory exists but holds only a stray `node_modules` symlink into the main checkout. |
| 2 | `curl -sk -o /dev/null -w '%{http_code}' http://localhost:8080/docs` | `http_code=000` | **The probe as written is unusable**, independent of the blocker: nothing listens on `localhost:8080` (`ss -lnt` → no `:8080`). The gateway is a NodePort, not a localhost port-forward. Working equivalent recorded in §5. |
| 3 | `bats d2-signalloom/test/docs-platform.bats` | `ERROR: Test file "…/docs-platform.bats" does not exist.` — **rc=1** | Suite is present only on `feat/signal-loop-and-bootstrap-refactor`. |
| 4–6 | `test -f "…/Proposal — Signal Loom First User and Agent Onboarding (2026-Q3).md"` | **rc=0** (417 lines) | Proposal present. Probes 4, 5 and 6 are byte-identical to each other; they were run once and the result applied to all three. |

**Spec defect in probe 4–6.** As printed on the card the command is unquoted, so the shell
splits the vault path on its spaces and `test -f` receives eight arguments. It was quoted before
execution. Recorded here rather than silently corrected.

## 4. Out-of-tree build proof — the framework is fine

To separate *"the portal is broken"* from *"the portal is absent"*, the portal source was
extracted from the other branch into a scratch directory (`git archive` → `/tmp`; **no checkout,
no repo mutated, no sibling worktree touched**) and built there.

```
$ bun install                      # 463 packages installed [2.79s]        rc=0
$ bun run build                    # astro check && astro build
11:49:34 [build] ✓ Completed in 1.40s.
11:49:34 [starlight:pagefind] Found 14 HTML files.
11:49:34 [build] 14 page(s) built in 2.30s
11:49:34 [build] Complete!                                                  rc=0
```

Findings from that run, all of which carry into Phase 3:

* **Node compatibility is satisfied.** `astro@7.2.10` declares `engines.node >= 22.12.0`; this
  machine runs `node v26.8.1`. `bun 1.4.0`, `bats 1.13.0`.
* **Telemetry write is a real build blocker in a confined environment.** The first attempt died
  with `EACCES: permission denied, open '/home/andy/.config/astro/config.json'` from
  `@astrojs/telemetry`. The build only succeeds with `ASTRO_TELEMETRY_DISABLED=1` (or a writable
  `XDG_CONFIG_HOME`). Any Phase 3 agent running under a sandbox profile, and any CI lane, must
  set it — otherwise the failure reads as an Astro crash, which is precisely the hard blocker
  this card was told to stop on.
* **One pre-existing content warning:** `/404.htmlEntry docs → 404 was not found.` Non-fatal;
  the build still exits 0. Worth closing in `SLON-P3-1`.
* **Production build path differs from the card's probe.** The `Dockerfile` builds on
  `node:22-alpine` with `npm ci` + `npm run build`, and requires a non-empty `SOURCE_ID` build
  argument (`RUN test -n "$SOURCE_ID"`). The card's `bun run build` probe exercises a different
  installer and a different Node major than the artifact that actually ships.
* **14 routes build**, covering `start/`, `roles/`, `operate/`, `demos/` and `reference/`.

## 5. Live cluster — real, and reconciled from the wrong branch

| Probe | Result |
| --- | --- |
| `kubectl get deploy,svc -A -l app.kubernetes.io/name=docs-signalloom` | `fe-signalloom/docs-signalloom` Deployment `1/1`, Service `ClusterIP:8080`, both **18h** old |
| `kubectl get httproute -A` | `fe-signalloom/signalloom-docs` present, **18h** old |
| `curl --resolve dashboard.osramp.acme.local:31436:172.18.0.5 https://…/docs/` | **200** |
| same, `/docs` (no trailing slash) | **308** |
| same, `/` | **200** |
| Deployed image | `zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/docs-signalloom:latest` |

Every Flux source in the cluster is an **`OCIRepository`**, not a `GitRepository` — there is no
git revision recorded anywhere in cluster state. The manifests and the image were published from
a working tree, and the only tree that contains them is
`feat/signal-loop-and-bootstrap-refactor`. **A live probe of `/docs` cannot be used as evidence
that the integration branch is ready.** This is the trap that carried through Phase 1: the
`SLON-P1-PRE` errata records `/docs/ -> 200 OK` as an observed fact, and it was — of a different
branch's code.

## 6. Branch topology

```
                47359d52  (2026-09-09 16:29:56 +0100)  common ancestor
                    │                                   docs portal ABSENT here
        ┌───────────┴────────────┐
        │                        │
   36 commits                4 commits
        │                        │
   a69cbba7                 3579e79b   feat/signal-loop-and-bootstrap-refactor
   integration/slon-v0.1.0        └── 56e35ea5 adds the whole docs-signalloom portal
   (HEAD, this worktree)              (2026-09-10 09:41:28 +0100)
```

`git rev-list --left-right --count integration/slon-v0.1.0...feat/signal-loop-and-bootstrap-refactor`
→ **`36  4`**. Neither branch is an ancestor of the other.

Positive presence/absence probes against the integration ref (`git cat-file -e`, which cannot be
blanked by a sandbox the way a bare `ls` can):

```
ABSENT   d2-signalloom/apps/docs-signalloom/package.json
ABSENT   d2-signalloom/apps/docs-signalloom/astro.config.mjs
ABSENT   d2-signalloom/test/docs-platform.bats
ABSENT   d2-signalloom/apps/fe-signalloom/base/docs-service.yaml
ABSENT   d2-signalloom/apps/fe-signalloom/base/docs-deployment.yaml
```

## 7. Baseline health of the integration branch (what *is* green)

| Check | Result |
| --- | --- |
| `git status --porcelain` | clean — no output |
| `git merge-base --is-ancestor integration/slon-v0.1.0 HEAD` | `rc=0` |
| `make signalloom-check` (release-pack + delivery contract + preflight roots) | **rc=0** — three checks passed |
| `make test-signalfusion-bats` (offline, no cluster) | **14/14 ok, rc=0** |
| Kanban board `SLON` | `HEALTH: ✓ healthy`; `backlog=3 done=11 in_progress=1`; no sibling card running concurrently |

**Not run, deliberately, and why.** `make test` runs the full end-to-end BATS suite against the
live cluster and mutates it. This card's role boundary is *validate phase readiness; do not
implement deliverables*, the blocker is a missing source tree rather than a failing test, and the
cluster is shared. Two offline suites plus the static contract check were run instead. This is a
declared coverage cap, not a claim of full baseline verification.

## 8. Consequences for the remaining Phase 3 cards

* **`SLON-P3-1`** (author onboarding guides and operator runbooks) has **no portal to author
  into** on its base ref. It would either fail immediately or — worse — invent a second portal
  from scratch, duplicating the one that already exists on the other branch.
* **Duplication risk is concrete, not theoretical.** The existing portal already ships
  `start/quick-start.md`, `start/first-agent.md`, `start/external-linux-agent.mdx`,
  `operate/stun-agent.mdx`, `demos/superadmin.md`, four `roles/*` pages and three `reference/*`
  pages. That is a substantial fraction of `SLON-P3-1`'s stated scope, already written.
* **`SLON-P3-2`** (adversarial tenant-isolation tests during onboarding) would assert against a
  cluster whose docs tier is running code absent from the branch under test — green results that
  prove nothing about the deliverable.
* **`SLON-P3-GOV`** cannot certify `/docs` from the integration branch until the portal is on it.

## 9. Recommended remediation — a Governor decision, not a preflight action

The fix is to land the docs portal on `integration/slon-v0.1.0`. **This card did not do it**, and
should not: the card's STOP rule forbids substituting a different ref to get past a blocker, its
Out of Scope forbids unrelated slice changes, and the merge is not small.

The four unmerged commits touch far more than documentation — `dashboard-signalloom/src/components/onboarding`,
`dashboard-signalloom/src/api`, `dashboard-signalloom/src/auth`, `fe-signalloom/base`,
`fe-signalloom/src/tests`, `signalloom-stun-sentinel`, `inf-bao/controllers/base`,
`d2-infra/components/{cert-manager,ingress}`, `d2-k8s-afm`, `scripts`, `Makefile`, `AGENTS.md`,
`ISA.md` and `.github/workflows`. The onboarding-component overlap collides directly with
already-merged Phase 1 SLON deliverables. A blind `git merge` is a conflict-resolution exercise
with Phase 1 regression risk.

Three options, in the order I would take them:

1. **Preferred — scoped subtree adoption.** Take only the docs slice onto the integration branch:
   `d2-signalloom/apps/docs-signalloom/**`, `d2-signalloom/apps/fe-signalloom/base/docs-service.yaml`,
   `docs-deployment.yaml`, the `signalloom-docs` rule in `gateway-route.yaml`, the
   `allow-docs-gateway-ingress` rule in `networkpolicy.yaml`, `d2-signalloom/test/docs-platform.bats`,
   and the `docs-signalloom` workload entry in the publish workflow. Verify with
   `bats d2-signalloom/test/docs-platform.bats` (nine structural tests, no cluster needed) plus a
   clean `bun run build`. Smallest blast radius; leaves the dashboard changes alone.
2. **Full merge of the four commits**, resolving the onboarding-component conflicts against Phase 1
   deliverables, with the Phase 1 and Phase 2 suites re-run afterwards. Correct but expensive, and
   it silently re-scopes Phase 3.
3. **Re-cut Phase 3 against `feat/signal-loop-and-bootstrap-refactor`.** Rejected — it abandons 36
   commits of merged Phase 1 and Phase 2 SLON work.

Whichever is chosen, `SLON-P3-1`'s scope needs re-baselining against the pages that already exist,
and `SLON-P3-2`'s probes need to target the branch under test rather than the live cluster.
Concrete replacement specs are in [`slon-p3-spec-tightening.md`](slon-p3-spec-tightening.md).

---

## Companion artifacts

| Document | Contents |
| --- | --- |
| [`slon-p3-docs-portal-provenance.md`](slon-p3-docs-portal-provenance.md) | Full provenance and gap analysis of the docs portal: file inventory, interface contracts, cluster-versus-branch reconciliation |
| [`slon-p3-spec-tightening.md`](slon-p3-spec-tightening.md) | Corrected, unambiguous specs for `SLON-P3-1`, `SLON-P3-2` and `SLON-P3-GOV` |
| [`slon-p3-preflight-verification-record.md`](slon-p3-preflight-verification-record.md) | Structured per-command record: exit statuses, timestamps, tree hashes |
