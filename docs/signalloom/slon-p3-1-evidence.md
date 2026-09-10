# SLON-P3-1 — Documentation Portal Evidence

**Card:** SLON-P3-1 — Author complete user and dual-agent onboarding guides and operator runbooks in docs portal
**Created:** 2026-09-10 12:16:30+01:00
**Base ref:** `refs/heads/integration/slon-v0.1.0`
**Base commit:** `06c6c429b920d1124a7362f8ba3f39510f9f66d9`
**Worktree:** `/home/andy/src/.worktrees/6fd81/osramp-demo`
**Ancestry:** `git merge-base --is-ancestor integration/slon-v0.1.0 HEAD` → exit 0

---

## 1. What was published

| Route | Source file | Purpose |
| --- | --- | --- |
| `/docs/onboarding/user-journey/` | `src/content/docs/onboarding/user-journey.mdx` | First-user onboarding journey, sign-in through to Overview |
| `/docs/agents/dual-agent-onboarding/` | `src/content/docs/agents/dual-agent-onboarding.mdx` | Claiming `agent-nono-evidenced` and `agent-standard-baseline`, comparative telemetry |
| `/docs/security/nono-optionality/` | `src/content/docs/security/nono-optionality.mdx` | Dynamic Nono probe, confined path, unconfined fallback (SP-5) |
| `/docs/operations/demo-walkthrough/` | `src/content/docs/operations/demo-walkthrough.mdx` | Ninety-second partner runbook with spoken script, matching `make demo-signalloom-smoke` |

Supporting changes:

| Path | Change |
| --- | --- |
| `astro.config.mjs` | Added `Onboarding` and `Security` sidebar groups; added two entries to existing groups. No existing entry removed or re-slugged. |
| `scripts/link-audit.mjs` | New. Resolves every internal link in `dist/` to a file on disk. Carries a `--self-test` negative control. |
| `package.json` | Added the `audit:links` script. Dependencies untouched, so `npm ci` in the Dockerfile is unaffected. |
| `public/favicon.svg` | New. Closes a pre-existing defect — see §4. |
| `test/acceptance/docs.spec.ts` | New Chromium render spec for the four pages. |
| `test/acceptance/playwright.config.ts` | Added a `docs` project. No existing project altered. |
| `test/acceptance/SPEC-REGISTRY.tsv` | One appended row registering `docs.spec.ts` as `suite-only`. |

Every page carries a Mermaid architectural flow diagram, a troubleshooting table, and cross-links
to the other three.

---

## 2. Build log

```text
$ ASTRO_TELEMETRY_DISABLED=1 bun run --cwd d2-signalloom/apps/docs-signalloom build
$ astro check && astro build
...
 generating static routes
  ├─ /404.html
  ├─ /agents/dual-agent-onboarding/index.html      (+6ms)
  ├─ /demos/superadmin/index.html                  (+2ms)
  ├─ /index.html                                   (+2ms)
  ├─ /onboarding/user-journey/index.html           (+6ms)
  ├─ /operate/stun-agent/index.html                (+3ms)
  ├─ /operations/demo-walkthrough/index.html       (+3ms)
  ├─ /reference/documentation-rules/index.html     (+2ms)
  ├─ /reference/glossary/index.html                (+2ms)
  ├─ /reference/roadmap/index.html                 (+2ms)
  ├─ /roles/advanced/index.html                    (+1ms)
  ├─ /roles/platform-admin/index.html              (+1ms)
  ├─ /roles/security-team/index.html               (+1ms)
  ├─ /roles/view-only/index.html                   (+1ms)
  ├─ /security/nono-optionality/index.html         (+2ms)
  ├─ /start/external-linux-agent/index.html        (+2ms)
  ├─ /start/first-agent/index.html                 (+1ms)
  ├─ /start/quick-start/index.html                 (+1ms)
[starlight:pagefind] Found 18 HTML files.
[build] 18 page(s) built in 1.47s
[build] Complete!

BUILD_EXIT=0
```

`astro check` produced no errors; the build is gated on it by the `build` script
(`astro check && astro build`), so a non-zero check would have aborted before `astro build` ran.

Page count moved **14 → 18**, which is exactly the four new pages and nothing else.

---

## 3. Link audit report

```text
$ bun run audit:links
$ node scripts/link-audit.mjs --dist dist --base /docs --self-test
link-audit: self-test passed — a non-resolvable link is detected.
link-audit: base=/docs pages=18 internal_links_checked=491
link-audit: 0 unresolved internal links.

AUDIT_EXIT=0
```

The auditor resolves each internal `href`/`src` to a file on disk (`<path>`,
`<path>/index.html`, or `<path>.html`) rather than pattern-matching the URL text. A regex that
only checks whether a link *looks* like a docs URL would pass for a page that was never built.

The `--self-test` flag is not decoration. It injects a link that cannot resolve and requires the
auditor to flag it; if the auditor stays silent, it exits 3 and refuses to report a pass. Without
that control, "0 unresolved links" and "the auditor is broken" are the same output.

---

## 4. A pre-existing defect this audit found

The first audit run reported **18 unresolved links** — one on every page:

```text
  /index.html -> /docs/favicon.svg  (no file on disk for this target)
  ...one identical row per built page...
```

Starlight emits `<link rel="icon" href="/docs/favicon.svg">` into the head of every page, but the
application had no `public/` directory at all, so the asset was never built. Every page on the
deployed site has been requesting a 404 asset.

This predates the card: `git log -- public` returns nothing and `ls public` reported no such
directory on the base commit. It was fixed rather than exempted, because "zero broken internal
links" is the card's acceptance criterion and an auditor configured to skip assets would have
reported a vacuous pass. A minimal `public/favicon.svg` was added; the re-run reports zero.

---

## 5. Platform contract suite

```text
$ bats d2-signalloom/test/docs-platform.bats
1..9
ok 1 Docs build uses Astro Starlight at the docs base path
ok 2 Docs nginx serves health and fail-closed static routes
ok 3 Docs Deployment uses the signed image and hardened runtime
ok 4 Docs source identity covers its build context
ok 5 Docs publishing passes the source identity build argument
ok 6 Docs Service selects the docs workload on port 8080
ok 7 Docs HTTPRoute owns the docs prefix without rewriting it
ok 8 Docs NetworkPolicy allows only Gateway ingress
ok 9 Docs content covers the requested user journeys

BATS_EXIT=0
```

```text
$ bats test/acceptance-spec-coverage.bats
1..7
ok 1 the guard can read every project in playwright.config.ts
ok 2 every spec on disk has exactly one registry row, and every row has a spec
ok 3 every registry runner is a known kind, and every non-CI row gives a reason
ok 4 a spec matches a playwright project if and only if the registry says so
ok 5 every ci: row names a stage that really runs that spec
ok 6 every spec a CI stage runs is registered as ci:
ok 7 every make: row names a target whose recipe runs that spec

GUARD_EXIT=0
```

Test 4 is the one that matters here: it asserts a spec is claimed by a Playwright project **if and
only if** the registry says so. It is what stops `docs.spec.ts` becoming a spec that no project
claims — which Playwright reports as a smaller total and exit 0, never as an error.

---

## 6. Chromium render verification

### Why not the cluster

`docs/signalloom/slon-p3-docs-portal-provenance.md` §4 established, during SLON-P3-PRE, that every
Flux source in the demo cluster is an `OCIRepository` carrying no git revision, and that the
running `docs-signalloom` image was published from `feat/signal-loop-and-bootstrap-refactor`. A
live probe of `https://dashboard.osramp.acme.local/docs` is therefore evidence about a deployed
artifact and **never** about the branch under test. SLON-P1-PRE already recorded `/docs/ -> 200 OK`
as a property of the integration line when it was a property of a different branch.

The spec therefore drives a locally served build of the checked-out tree.

### The run

```text
$ ASTRO_TELEMETRY_DISABLED=1 bunx astro preview --port 4325 --host 127.0.0.1
Preview server running at http://127.0.0.1:4325

$ for p in "" onboarding/user-journey/ agents/dual-agent-onboarding/ \
           security/nono-optionality/ operations/demo-walkthrough/; do
    curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:4325/docs/$p"
  done
/docs/                                     200
/docs/onboarding/user-journey/             200
/docs/agents/dual-agent-onboarding/        200
/docs/security/nono-optionality/           200
/docs/operations/demo-walkthrough/         200

$ PLAYWRIGHT_BROWSERS_PATH=/tmp/slon-p3-1-ms-playwright PW_CHANNEL=chromium \
  DOCS_BASE_URL=http://127.0.0.1:4325/docs \
  bunx playwright test docs.spec.ts --project=docs --reporter=list

Running 5 tests using 1 worker
  ✓  1 onboarding/user-journey renders its heading and navigation      (356ms)
  ✓  2 agents/dual-agent-onboarding renders its heading and navigation (296ms)
  ✓  3 security/nono-optionality renders its heading and navigation    (294ms)
  ✓  4 operations/demo-walkthrough renders its heading and navigation  (322ms)
  ✓  5 every new page is reachable from the sidebar of every other new page (259ms)

  5 passed (1.9s)
PW_EXIT=0
```

### Negative control

A passing browser suite proves nothing until it has been shown to fail. Repointing the same spec
at a base that serves no docs:

```text
$ DOCS_BASE_URL=http://127.0.0.1:4325/nonexistent-base ... --project=docs
  5 failed
NEG_EXIT=1
```

The suite asserts on HTTP status, on exact `<h1>` text, and on the presence of the sidebar anchor
for each new slug — so a 404 shell, an empty render, and an unwired sidebar entry each fail
distinctly.

### Environment note

`PW_CHANNEL=chromium` is required in this sandboxed shell. Real branded Chrome at
`/opt/google/chrome/chrome` is mode `-rwxr-xr-x` but exec is denied to this process
(`spawn /opt/google/chrome/chrome EACCES`) — the sandbox, not a permission bit. This is the exact
fallback `playwright.config.ts` documents at the `CHANNEL` constant. Browsers were installed to
`/tmp/slon-p3-1-ms-playwright` because the repository's `.cache` is a symlink into the principal
checkout, which this worktree may not write to.

---

## 7. Content accuracy check (anti-fabrication)

Every `/api/...` path appearing in the four new pages was extracted and required to exist
elsewhere in the repository. This substitutes for the cross-vendor review that was not run — see
the delegation note in the errata.

```text
PASS  /api/onboarding/complete
PASS  /api/onboarding/skip
PASS  /api/onboarding/state
PASS  /api/onboarding/status
PASS  /api/v1/agents
PASS  /api/v1/agents/claim
PASS  /api/v1/agents/claim/{claim_id}
PASS  /api/v1/agents/claims
PASS  /api/v1/agents/{agent_id}/claim
PASS  /api/v1/agents/{agent_id}/telemetry

0 orphans
```

Source of truth for each: `d2-signalloom/apps/fe-signalloom/src/api_compat.py` route decorators
(lines 3992–4205) and `d2-signalloom/apps/dashboard-signalloom/src/api/agentClaim.ts`.

Other load-bearing facts and where they were read from:

| Claim in the docs | Verified against |
| --- | --- |
| Cross-tenant claim returns HTTP 409 `claim_conflict` | `api_compat.py` conflict branch, `raise APIError(409, "claim_conflict", …)` |
| Claims persist in `public.agent_claims` | `api_compat.py` INSERT statement |
| Workload profile labels `nono-evidenced` / `standard-baseline` | `infra/agent-swarm/agent-*/deployment.yaml` label blocks |
| SPIFFE IDs of both demo agents | `infra/agent-swarm/agent-*/deployment.yaml` annotations |
| Probe checks binary then Landlock LSM | `apps/fe-signalloom-agents/probe-nono-capability.sh`, `check_landlock_lsm()` |
| Fallback warning text and `nono_capability_available:false` | same script, `probe_nono_capability()` fallback branch |
| `NONO_FORCE_FALLBACK`, `NONO_BIN`, `NONO_AUDIT_OUT`, `SPIFFE_SOCKET`, `HEARTBEAT_INTERVAL` defaults | same script, configuration defaults block |
| Smoke suite is three stages with a 90s SLA on ports 30754 / 15556 / 18000 | `scripts/demo-signalloom-smoke.sh` |

---

## 8. Anti-criteria

| Assertion | Result |
| --- | --- |
| No file under `dashboard-signalloom/src`, `apps/fe-signalloom/` or `infra/agent-swarm/` modified | `git status --porcelain` → NONE |
| No existing sidebar entry removed or re-slugged | all 12 pre-existing slugs still present in `astro.config.mjs` |
| No push to any remote, no pull request | none issued |
| No cluster mutation | read-only `kubectl get` only |
| No invented API endpoint | §7, 0 orphans |

---

## 9. Reproduce this

```bash
ASTRO_TELEMETRY_DISABLED=1 bun run --cwd d2-signalloom/apps/docs-signalloom build
bun run --cwd d2-signalloom/apps/docs-signalloom audit:links
bats d2-signalloom/test/docs-platform.bats
bats test/acceptance-spec-coverage.bats

# browser render check
ASTRO_TELEMETRY_DISABLED=1 bunx --bun astro preview \
  --root d2-signalloom/apps/docs-signalloom --port 4325 --host 127.0.0.1 &
DOCS_BASE_URL=http://127.0.0.1:4325/docs PW_CHANNEL=chromium \
  bunx playwright test docs.spec.ts --project=docs
```
