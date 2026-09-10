# SLON-P3-PRE — Structured Verification Record

**Card:** `SLON-P3-PRE`
**Run window:** 2026-09-10 11:44 → 11:50 +01:00
**Worktree:** `/home/andy/src/.worktrees/b5c28/osramp-demo` (reached via the symlink `/home/andy/.cline/worktrees/b5c28/osramp-demo`)
**Companion to:** [`slon-p3-preflight-proof.md`](slon-p3-preflight-proof.md)

Consolidates the card's Required Evidence items 4, 5 and 6 into one record. The card requested
three separately-numbered "structured verification records" whose descriptions are identical
template text; there is one set of commands and one set of results, so producing three files
would have been padding. Recorded here as a deviation rather than made silently.

---

## 1. Immutable identity

| Field | Value |
| --- | --- |
| `git rev-parse HEAD` | `a69cbba7a1255a4b95668c2859b62241d39c003b` |
| `git rev-parse --abbrev-ref HEAD` | `HEAD` (detached — expected for a Kanban runtime worktree) |
| `git rev-parse refs/heads/integration/slon-v0.1.0` | `a69cbba7a1255a4b95668c2859b62241d39c003b` |
| `git rev-parse HEAD^{tree}` | `16cb7da73786f98acc845c4a253bd169e5638cf8` |
| `git merge-base --is-ancestor integration/slon-v0.1.0 HEAD` | `rc=0` |
| `git status --porcelain` at start | empty (clean) |
| Merge base with `feat/signal-loop-and-bootstrap-refactor` | `47359d5261fcb74399561c3eaa2d9f87ba2881a1` |
| `feat/signal-loop-and-bootstrap-refactor` tip | `3579e79b3e98a8e1abfc1b8c050ba06ca46bdb07` |
| Commit introducing the docs portal | `56e35ea57ef0ac34add59cba7f9a83eef5dde8a7` |
| Divergence `--left-right --count` | `36  4` |

## 2. Toolchain

| Tool | Version | Path |
| --- | --- | --- |
| `bun` | `1.4.0` | `/home/andy/.local/bin/bun` |
| `node` | `v26.8.1` | `/home/andy/.local/bin/node` |
| `bats` | `Bats 1.13.0` | `/home/linuxbrew/.linuxbrew/bin/bats` |
| `kubectl` context | `kind-osramp` | — |
| `astro` engine requirement | `node >= 22.12.0` (from `package-lock.json`) | satisfied by `v26.8.1` |

## 3. Required tests — command, exit status, verdict

| # | Command (as executed) | Exit | Output signature | Verdict |
| --- | --- | --- | --- | --- |
| T1 | `bun run --cwd d2-signalloom/apps/docs-signalloom build` | `1` | `error: Script not found "build"` | ❌ blocked — no `package.json` on this ref |
| T2 | `curl -sk -m 8 -o /dev/null -w '%{http_code}' http://localhost:8080/docs` | `0` | `http_code=000` | ❌ unusable probe — `ss -lnt` shows no listener on `:8080` |
| T3 | `bats d2-signalloom/test/docs-platform.bats` | `1` | `ERROR: Test file "…/docs-platform.bats" does not exist.` / `not ok 1 bats-gather-tests` | ❌ blocked — suite absent from this ref |
| T4 | `test -f "<proposal path>"` | `0` | 417 lines | ✅ |
| T5 | identical to T4 | `0` | — | ✅ (deduplicated) |
| T6 | identical to T4 | `0` | — | ✅ (deduplicated) |

## 4. Supplementary probes

| Probe | Command | Exit | Result |
| --- | --- | --- | --- |
| P1 | `git ls-files -- d2-signalloom/apps/docs-signalloom` | `0` | `count=0` — nothing tracked |
| P2 | `git cat-file -e integration/slon-v0.1.0:…/package.json` | `1` | ABSENT |
| P3 | `git cat-file -e integration/slon-v0.1.0:…/astro.config.mjs` | `1` | ABSENT |
| P4 | `git cat-file -e integration/slon-v0.1.0:…/docs-platform.bats` | `1` | ABSENT |
| P5 | `git cat-file -e integration/slon-v0.1.0:…/docs-service.yaml` | `1` | ABSENT |
| P6 | `git cat-file -e integration/slon-v0.1.0:…/docs-deployment.yaml` | `1` | ABSENT |
| P7 | `git show integration/…:…/gateway-route.yaml` grep for path values | `0` | `/`, `/dex`, `/api` only — no `/docs` |
| P8 | `rg -i 'astro\|starlight'` over `git ls-files` | `1` | no match anywhere in the tracked tree |
| P9 | `kubectl get deploy,svc -A -l app.kubernetes.io/name=docs-signalloom` | `0` | Deployment `1/1`, Service `ClusterIP:8080`, age `18h` |
| P10 | `kubectl get httproute -A` | `0` | `fe-signalloom/signalloom-docs` present, age `18h` |
| P11 | `kubectl get gitrepository -A` | `0` | none — all Flux sources are `OCIRepository` |
| P12 | `curl -sk --resolve dashboard.osramp.acme.local:31436:172.18.0.5 https://…/docs/` | `0` | `200` |
| P13 | same, `/docs` | `0` | `308` |
| P14 | same, `/` | `0` | `200` |
| P15 | deployed image | `0` | `zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/docs-signalloom:latest` |

## 5. Out-of-tree build proof

Source extracted with `git archive feat/signal-loop-and-bootstrap-refactor d2-signalloom/apps/docs-signalloom`
into `/tmp/slon-p3-docsbuild`. **No checkout was switched, no repository file was modified, no
sibling worktree was touched, and the main checkout's `node_modules` was not used** (a fresh
`bun install` was run in the scratch tree, so no cache write leaked into another checkout).

| Step | Command | Exit | Result |
| --- | --- | --- | --- |
| B1 | `bun install` | `0` | `463 packages installed [2.79s]`; `astro@7.2.10`, `@astrojs/starlight@0.42.0`, `@astrojs/check@0.9.4`, `mermaid@11.17.2`, `typescript@5.7.3` |
| B2 | `bun run build` (no env) | `1` | `EACCES: permission denied, open '/home/andy/.config/astro/config.json'` at `@astrojs/telemetry/dist/config.js:59` |
| B3 | `ASTRO_TELEMETRY_DISABLED=1 XDG_CONFIG_HOME=… bun run build` | `0` | `astro check` passed; `14 page(s) built in 2.30s`; pagefind indexed 14 HTML files; `[build] Complete!` |

Warnings recorded from B3, neither fatal:

* `/404.htmlEntry docs → 404 was not found.`
* `(!) Some chunks are larger than 500 kB after minification` (vite/rolldown, from `mermaid`).

**B2 is the finding that matters operationally.** It is a sandbox/permissions failure that
presents as an Astro stack trace. Any Phase 3 agent hitting it without this record would classify
it as the card's declared hard blocker — *"Astro Starlight framework crash"* — and stop for the
wrong reason.

## 6. Baseline health of the integration branch

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| H1 | `git status --porcelain` | `0` | clean, before and after |
| H2 | `make signalloom-check` | `0` | security release-pack template passed; delivery contract passed (`main → integration/signalloom-d2-v2.5.0 → osramp-demo`); preflight roots passed (4 git roots, 6 required paths) |
| H3 | `make test-signalfusion-bats` | `0` | `1..14`, 14 × `ok`, 0 failures, 0 skips |
| H4 | `kanban-check.sh --shortcode SLON progress` | `0` | `HEALTH: ✓ healthy`; `backlog=3 done=11 in_progress=1`; only `P3-PRE` in progress — no sibling collision |

**Declared coverage cap.** `make test` (full end-to-end BATS against the live cluster) was **not**
run. It mutates a shared cluster, the blocker is a missing source tree rather than a failing test,
and this card's role boundary is validation, not implementation. H2 and H3 are offline
substitutes. This is a deliberate, recorded cap — not a claim of full baseline verification.

## 7. Artifacts produced

| Path | Purpose |
| --- | --- |
| `docs/signalloom/slon-p3-preflight-proof.md` | Primary preflight verdict and evidence |
| `docs/signalloom/slon-p3-docs-portal-provenance.md` | Portal provenance, file inventory, interface contracts, gap analysis |
| `docs/signalloom/slon-p3-spec-tightening.md` | Corrected specs for `SLON-P3-1`, `P3-2`, `P3-GOV`; proposed `SLON-P3-0` |
| `docs/signalloom/slon-p3-preflight-verification-record.md` | This record |
| `docs/README.md` | One appended index row (shared file — single-line edit only) |

## 8. Deviations from the card contract

| Deviation | Reason |
| --- | --- |
| Deliverables "artifact 3/4/5/6" delivered as three substantive documents, not four | The four descriptions are identical template filler. Three genuinely distinct documents were produced; a fourth would have been padding. Recorded rather than silently dropped. |
| Approach steps 5–8 ("iterative validation step N") not executed as written | Identical generated filler with no distinct content. The substantive validation they gesture at — boundary conditions, error propagation, log emission — is covered by §3–§6. |
| Required test T2 replaced with a working equivalent | The printed form targets a port with no listener. Both the printed form and the working form were run, and both results are recorded. |
| `make test` not run | See §6 coverage cap. |
| Docs portal **not** merged onto the integration branch | The card's STOP rule forbids substituting a different ref to get past a blocker, and its Out of Scope forbids unrelated slice changes. The merge is a Governor decision; the scoped plan is in §9 of the proof. |
