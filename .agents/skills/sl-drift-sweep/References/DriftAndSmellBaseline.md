# Reference: Three-Axis Drift, Deep-Module & Code-Smell Baseline

Integrates 12 Matt Pocock skills (`49dd158`, vendored in [`../vendor/pocock-skills/THIRD_PARTY_NOTICES.md`](../vendor/pocock-skills/THIRD_PARTY_NOTICES.md)) for whole-codebase governance in `osramp-demo`.

---

## 1. Why Three Separate Axes (`code-review` + `improve-codebase-architecture`)

A multi-agent commit wave can pass one axis and fail the others:
- **Standards pass, Spec fail**: Code obeys every linter but fragments one architectural requirement across 130+ micro-proposals or leaves partial handler coverage.
- **Spec pass, Standards fail**: Every endpoint implements RFC 9110 behavior, but uses 800+ copy-pasted inline checks and leaves 250+ `docs-lint` prose failures.
- **Standards & Spec pass, Architecture fail**: Individual files pass linters and specs, but shallow pass-through modules leak internal details across package seams.

Reporting `## Axis A: Standards`, `## Axis B: Spec`, and `## Axis C: Architecture & Seam Depth` separately prevents green unit tests from masking structural mess.

---

## 2. Axis A: Standards & Fowler Code-Smell Baseline ([`code-review`](../vendor/pocock-skills/code-review/SKILL.md))

### Repository Standards (Hard Violations)
1. **Documentation Lint (`make docs-lint` / `scripts/docs-lint.sh`)**:
   - Sentences must be ≤ 25 words.
   - Prose must contain zero semicolons (`;`).
   - Inline backtick paths resembling repo paths must exist on disk (or describe historical deleted components in prose without dead path spans).
   - Zero `<!-- docs-lint:` `off -->` markers outside `docs/documentation-style.md`.
2. **Worktree Hygiene (`scripts/check-worktree-hygiene.sh` + [`git-guardrails-claude-code`](../vendor/pocock-skills/git-guardrails-claude-code/SKILL.md))**:
   - Secondary worktrees must live under `~/src/.worktrees/osramp-demo/`, never inside `$REPO_ROOT/` or under an ad hoc `/tmp` root.
   - Pruning policy: only prune external worktrees when they are strictly **> 21 days old**, of **`osramp` type**, and have **zero uncommitted changes**.
3. **Containment Preservation**:
   - Static drift remediation must never resume, restart, reconcile, replace, or otherwise mutate a stunned or contained workload.

### Fowler Code-Smell Heuristics (Judgement Calls → Deduplication Jobs)
| Smell | Agentic Drift Symptom in `osramp-demo` | Canonical Remediation Pattern |
|---|---|---|
| **Duplicated Code** | Identical `OPTIONS` / `HEAD` / `405 Allow` / `io.LimitReader` blocks pasted across handlers | Extract `httputil.go` (Go), `http-gate.ts` (TS harnesses), and `normalize_allow` / `_gate_route` (Python) |
| **Shotgun Surgery** | One protocol rule change requires editing 30+ microservice files | Centralize per-module middleware (`headBodySuppressingMiddleware`, `requireReadMethod`, `requirePostMethod`) |
| **Divergent Change** | Same service file (`a2a/service.py`, `fleet-manager/main.go`) modified 10–16x in one branch | Consolidate route table and method dispatch into a single table-driven gate |
| **Primitive Obsession** | Hardcoded `"GET, HEAD, OPTIONS"` strings repeated at every 204/405 site | Derive `Allow` headers via `normalizeAllow(methods)` automatically adding `HEAD` (when `GET` present) and `OPTIONS` |
| **Speculative Generality** | Unused parameters, dead mock branches, or unreferenced helper stubs | Inline or delete until exercised by a real contract test |

---

## 3. Axis B: Spec & Proposal Fidelity ([`domain-modeling`](../vendor/pocock-skills/domain-modeling/SKILL.md))

1. **Proposal Sprawl Consolidation**:
   - Consolidate per-commit micro-proposals that share `Mission: —` in `docs/README.md` into a single canonical ADR.
   - Retain all named Mission proposals. Keep codes such as `SLON`, `SLER`, `SLTM`, `SFDP`, `SLGC`, `SLRC`, `SLFA`, `SLWD`, and `SLDP`.
2. **Decision Records Index Sync (`test/docs-index-sync.bats`)**:
   - Every `RECORDS`-tier document in `docs/` must have an encoded link in `docs/README.md` (`## 5 · Decision records`), and no deleted proposal link may remain.

---

## 4. Axis C: Whole-Codebase Deepening & Seams ([`codebase-design`](../vendor/pocock-skills/codebase-design/SKILL.md), [`improve-codebase-architecture`](../vendor/pocock-skills/improve-codebase-architecture/SKILL.md), [`setup-ts-deep-modules`](../vendor/pocock-skills/setup-ts-deep-modules/SKILL.md))

1. **The Deletion Test**:
   - Imagine deleting a module. If complexity vanishes, it was a shallow pass-through. If complexity reappears across N callers, it is a deep module earning its keep.
2. **Design It Twice ([`DESIGN-IT-TWICE.md`](../vendor/pocock-skills/codebase-design/DESIGN-IT-TWICE.md))**:
   - Before extracting a shared helper across services, compare at least two radically different interface shapes on **depth**, **payoff**, **locality**, and **seam placement**.
3. **TypeScript Root Entry-Point Boundaries**:
   - External callers and tests import through a package's root entry points (`http-gate.ts`, `index.ts`), never reaching into private subfolder internals.

---

## 5. Mutation Falsifiability Checklist ([`tdd`](../vendor/pocock-skills/tdd/SKILL.md) + Diff Proof)

Before trusting any "mutation test failed" result:
1. **Verify the mutation changed bytes on disk**: Run `git diff <mutated-file>` and assert the expected line changed. A `sed` pattern that matches 0 lines leaves the file unchanged.
2. **Verify the test passed BEFORE the mutation**: A test with a bad path or missing environment variable fails without the mutation. This produces a false red.
3. **Verify the failure message names the mutated invariant**: Check that the test fails on the specific assertion (`Allow = "GET, HEAD", want GET, HEAD, OPTIONS`), not a compile error.
