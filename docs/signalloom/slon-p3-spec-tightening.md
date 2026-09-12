# SLON-P3 — Specification Tightening for the Remaining Phase 3 Cards

**Produced by:** `SLON-P3-PRE` preflight, 2026-09-10 11:49:56+01:00
**Base ref:** `refs/heads/integration/slon-v0.1.0` @ `a69cbba7a1255a4b95668c2859b62241d39c003b`
**Companion to:** [`slon-p3-preflight-proof.md`](slon-p3-preflight-proof.md) · [`slon-p3-docs-portal-provenance.md`](slon-p3-docs-portal-provenance.md)

Part of a preflight's job is to make each downstream task spec unambiguous. These are
**recommendations**, not applied changes — Phase 3 card specs live in the proposal and on the
Kanban board, and the runtime-state boundary forbids this card from mutating either. They are
reproduced in the proposal errata for the Governor to action.

---

## 0. Blocking prerequisite — applies to every card below

None of `SLON-P3-1`, `SLON-P3-2` or `SLON-P3-GOV` can be executed until the docs portal is on
`integration/slon-v0.1.0`. Add an explicit remediation card ahead of them:

> **`SLON-P3-0` — Adopt the docs-signalloom portal onto the integration branch.**
> Scope: the seven-path subtree listed in §5 of the provenance document, and nothing else.
> Acceptance: `bats d2-signalloom/test/docs-platform.bats` → 9/9, and
> `ASTRO_TELEMETRY_DISABLED=1 bun run --cwd d2-signalloom/apps/docs-signalloom build` → rc=0
> with 14 pages. Both offline.
> Explicitly forbidden: merging `dashboard-signalloom/src/{api,auth,components/onboarding}` from
> `feat/signal-loop-and-bootstrap-refactor` — those files were changed on the integration line by
> `SLON-P1-1`/`P1-2`/`P1-3` and a merge is a Phase 1 regression risk, not a docs change.

Dependency edges become `SLON-P2-GOV → SLON-P3-PRE → SLON-P3-0 → {SLON-P3-1, SLON-P3-2} → SLON-P3-GOV`.

---

## 1. `SLON-P3-1` — Author onboarding guides and operator runbooks

### What the current spec gets wrong

* It reads as *author from scratch*. Twelve content pages already exist, covering a substantial
  fraction of the stated scope. Left as written, this card duplicates work that is already done
  and may restructure a working sidebar to match its own invention.
* Its acceptance is *"clean Astro build; zero broken links"*. A clean build is necessary and
  nowhere near sufficient — Astro will happily build 14 pages of nothing. And **nothing in the
  repository currently checks links**: there is no link-checker dependency in `package.json`, and
  `astro check` type-checks components, it does not crawl hrefs.
* The proposal names target paths `/docs/onboarding` and `/docs/agents`. The portal's actual
  information architecture is `start/`, `operate/`, `roles/`, `demos/`, `reference/`. Following
  the proposal literally creates a second, parallel IA.

### Recommended replacement

**Scope:** *extend* the existing portal. Specifically —

| Gap | Where it belongs in the existing IA |
| --- | --- |
| Dual-agent claim workflow (`agent-nono-evidenced` vs `agent-standard-baseline`) | new `start/dual-agent-claim.md`, sidebar group "Start here" |
| Nono optionality: capability probe, `nono_capability_available: false` fallback, unconfined execution | new `operate/nono-optionality.md`, sidebar group "Operate agents" |
| First-user onboarding wizard (the `SLON-P1-3` flow), server-side status via `GET /api/onboarding/status` | extend `start/quick-start.md` |
| Navigation 3-tier hierarchy (View / Control / Design, per shared pattern **SP-2**) | extend `roles/platform-admin.md` |
| Close the existing `/404.htmlEntry docs → 404 was not found.` build warning | `src/content/docs/404.md` |

**Explicitly out of scope for `SLON-P3-1`:** restructuring the existing sidebar, rewriting the
four `roles/*` pages, or renaming any existing slug. Existing content is amended, not replaced.

**Acceptance — replace the current row with all five:**

1. `ASTRO_TELEMETRY_DISABLED=1 bun run --cwd d2-signalloom/apps/docs-signalloom build` → rc=0.
2. Built page count **≥ 19** (14 existing + 4 new + 404), asserted from the build output.
3. Zero build warnings — in particular the `404.html` entry warning is gone.
4. **Link checking is a deliverable, not an assumption.** Add a real check and wire it to a
   Makefile target; assert it exits 0 with zero broken internal links. The existing
   `docs-platform.bats` is the natural home for the assertion.
5. `bats d2-signalloom/test/docs-platform.bats` → still 9/9, plus a new test asserting each new
   slug is reachable from `astro.config.mjs`'s sidebar (a page not in the sidebar is orphaned even
   though it builds).

**Environment note that must be on the card:** the build fails with
`EACCES … /home/andy/.config/astro/config.json` from `@astrojs/telemetry` unless
`ASTRO_TELEMETRY_DISABLED=1` is set. Under a sandbox profile this reads as an Astro crash and will
trip the phase's declared hard blocker for the wrong reason.

---

## 2. `SLON-P3-2` — Adversarial tenant-isolation tests during onboarding

### What the current spec gets wrong

* Its natural probe target is the live cluster, which — as established — runs code from a branch
  that is not under test. Green results would prove nothing about the deliverable. This is the
  same class of error as the Phase 1 `/docs/ -> 200 OK` record.
* "Adversarial" is undefined. Without a stated falsification target, an adversarial suite that
  goes green is indistinguishable from one that asserts nothing.

### Recommended replacement

**State the falsification target explicitly.** For each assertion, name the mutation that must
make it fail, and prove the mutation fails it. A tenant-isolation test that stays green when the
`WHERE tenant_id = ?` clause is deleted is not a test.

**Split the suite by transport, and say which is authoritative:**

| Layer | Instrument | Authoritative for |
| --- | --- | --- |
| Manifest / policy | `yq` + `bats` against the checked-out tree | **Yes** — this is the branch under test |
| API contract | request/response assertions against a locally-run service | Yes |
| Live cluster | `kubectl` + `curl` | **No** — corroborating only, and every result must record the deployed image digest alongside it |

**Add three assertions the current spec does not have:**

1. Cross-tenant read of onboarding status returns 403/404, never an empty 200 — an empty result is
   indistinguishable from "no such tenant" and launders a missing filter into a pass.
2. Per shared pattern **SP-1**, no authoritative onboarding state in `localStorage` or module
   memory: assert the client re-resolves through `GET /api/onboarding/status` after a reload.
3. Per shared pattern **SP-5**, the Nono-absent path logs `nono_capability_available: false` and
   still schedules — assert against a probe stub that reports absence, not merely against a host
   that happens to have `nono` installed.

**Acceptance:** every assertion above, plus a recorded mutation-kill result for each — the
mutation applied, the test that caught it, and the restored tree hash.

---

## 3. `SLON-P3-GOV` — Final programme certification

### What the current spec gets wrong

Nothing structural, but it inherits the blind spot: certifying `/docs` from a live probe would
certify the wrong branch.

### Recommended additions to the certification checklist

1. Re-run `bats d2-signalloom/test/docs-platform.bats` **against the merged integration tree**,
   and record the tree hash alongside the result.
2. Record the docs image digest actually deployed, and reconcile it against the `SOURCE_ID`
   computed from the integration tree. If they differ, the cluster is not running the certified
   branch and the live evidence is void.
3. Confirm `SLON-P3-0` landed only the seven-path subtree — diff the merge against the list in the
   provenance document and reject any `dashboard-signalloom/src/{api,auth,components/onboarding}`
   change that arrived with it.
4. Confirm the `signalloom-docs` HTTPRoute on the integration branch carries **no filters** — the
   portal owns `/docs` through Astro `base`, so a prefix rewrite would silently break every
   asset URL while `/docs/` still returned 200.
5. Per **SP-4**, halt in `Review` for human confirmation before advancing to `Done`.

---

## 4. Board-level defects observed, for the Governor

| # | Defect | Recommendation |
| --- | --- | --- |
| B1 | `SLON-P3-PRE`'s "verified facts" were compiled against the main checkout (`feat/signal-loop-and-bootstrap-refactor`), not against the card's own base ref | Compile card facts from the declared `baseRef`, never from `$PWD` of the board repo |
| B2 | Required test `curl … http://localhost:8080/docs` targets a port nothing listens on | Replace with the NodePort form: `curl -sk --resolve dashboard.${CLUSTER_DOMAIN}:${HTTPS_NODEPORT}:${NODE_IP} https://dashboard.${CLUSTER_DOMAIN}:${HTTPS_NODEPORT}/docs/` |
| B3 | Required tests 4, 5 and 6 are byte-identical, and the path is unquoted so the shell word-splits it on spaces | Deduplicate; quote the path |
| B4 | Deliverables 3–6 and approach steps 5–8 are template filler ("artifact 3", "iterative validation step 7") with no distinct content | Drop generated filler from compiled cards — it forces either padding or an undocumented deviation |
| B5 | The card's single declared hard blocker (Astro crash / Node incompatibility) does not cover the failure that actually occurred | Add "declared source tree absent from base ref" as a first-class blocker class for every preflight card |
