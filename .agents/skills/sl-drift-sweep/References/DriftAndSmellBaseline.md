# Reference: Two-Axis Drift & Code-Smell Baseline for Signal Loom

Derived from Matt Pocock's `code-review` skill (`49dd158`) and adapted for post-sprint multi-agent drift in `osramp-demo`.

---

## 1. Why Two Separate Axes

A multi-agent commit wave can pass one axis and fail the other:
- **Standards pass, Spec fail**: Code obeys every linter but fragments one architectural requirement across 130+ micro-proposals or leaves partial handler coverage.
- **Spec pass, Standards fail**: Every endpoint implements RFC 9110 behavior, but uses 800+ copy-pasted inline checks and leaves 250+ `docs-lint` prose failures.

Reporting `## Axis A: Standards` and `## Axis B: Spec` separately prevents green unit tests from masking structural mess.

---

## 2. Axis A: Standards & Fowler Code-Smell Baseline

### Repository Standards (Hard Violations)
1. **Documentation Lint (`make docs-lint` / `scripts/docs-lint.sh`)**:
   - Sentences must be ≤ 25 words.
   - Prose must contain zero semicolons (`;`).
   - Inline backtick paths resembling repo paths must exist on disk (or describe historical deleted components in prose without dead path spans).
   - Zero docs-lint turn-off markers outside `docs/documentation-style.md`.
2. **Worktree Hygiene (`scripts/check-worktree-hygiene.sh`)**:
   - Secondary worktrees must never be created inside `$REPO_ROOT/` (including `$REPO_ROOT/.claude/worktrees/`).
   - Pruning policy: only prune external worktrees when they are strictly **> 21 days old**, of **`osramp` type**, and have **zero uncommitted changes**.

### Fowler Code-Smell Heuristics (Judgement Calls → Deduplication Jobs)
| Smell | Agentic Drift Symptom in `osramp-demo` | Canonical Remediation Pattern |
|---|---|---|
| **Duplicated Code** | Identical `OPTIONS` / `HEAD` / `405 Allow` / `io.LimitReader` blocks pasted across handlers | Extract `httputil.go` (Go), `http-gate.ts` (TS harnesses), and `normalize_allow` / `_gate_route` (Python) |
| **Shotgun Surgery** | One protocol rule change requires editing 30+ microservice files | Centralize per-module middleware (`headBodySuppressingMiddleware`, `requireReadMethod`, `requirePostMethod`) |
| **Divergent Change** | Same service file (`a2a/service.py`, `fleet-manager/main.go`) modified 10–16x in one branch | Consolidate route table and method dispatch into a single table-driven gate |
| **Primitive Obsession** | Hardcoded `"GET, HEAD, OPTIONS"` strings repeated at every 204/405 site | Derive `Allow` headers via `normalizeAllow(methods)` automatically adding `HEAD` (when `GET` present) and `OPTIONS` |
| **Speculative Generality** | Unused parameters, dead mock branches, or unreferenced helper stubs | Inline or delete until exercised by a real contract test |

---

## 3. Axis B: Spec & Proposal Fidelity

1. **Proposal Sprawl Consolidation**:
   - Consolidate ungrouped micro-proposals that share `Mission: —` in `docs/README.md`. Combine related incremental passes into a single canonical proposal. Preserve all named Mission proposals.
2. **Decision Records Index Sync (`test/docs-index-sync.bats`)**:
   - Every `RECORDS`-tier document in `docs/` must have an encoded link in `docs/README.md` (`## 5 · Decision records`), and no deleted proposal link may remain.

---

## 4. Mutation Falsifiability Checklist (Catching Fake Green-Lights)

Before trusting any "mutation test failed" result:
1. **Verify the mutation changed bytes on disk**: Run `git diff <mutated-file>` and assert the expected line changed. A `sed` pattern that matches 0 lines leaves the file unchanged!
2. **Verify the test passed BEFORE the mutation**: Check that the test passes initially. If it fails before mutation, it gives a false failure signal.
3. **Verify the failure message names the mutated invariant**: Check that the test fails on the specific assertion (for example, `Allow = "GET, HEAD", want GET, HEAD, OPTIONS`), not a compile error.
