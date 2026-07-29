# Agentic Preflight Report -- osramp-demo (Signalloom D2 v2.5.0)

> Generated: 2026-07-29 | Project type: shell (mixed monorepo: Go + Python + TypeScript/React + Shell + K8s)
> Scanner: PreflightScorer v1 (automated) + heuristic assessment (agent-guided)
> Branch: `integration/signalloom-d2-v2.5.0`

## Composite Score: 37.6 / 100 -- Not Agent-Ready

| # | Category | Auto | Heur | Final | Weight | Weighted |
|---|----------|------|------|-------|--------|----------|
| 1 | Documentation | 2.1 | 1.7 | 1.9 | 0.20 | 3.8 |
| 2 | Test Architecture | 4.9 | 6.0 | 5.5 | 0.26 | 14.2 |
| 3 | Security & Static Analysis | 3.0 | 3.0 | 3.0 | 0.21 | 6.3 |
| 4 | Makefile & Build | 5.5 | 6.0 | 5.8 | 0.15 | 8.6 |
| 5 | TypeScript Strictness | -- | -- | -- | 0.00 | N/A |
| 6 | Dependency Management | 4.0 | 3.0 | 3.5 | 0.08 | 2.8 |
| 7 | Operational Readiness | 1.9 | 2.0 | 1.9 | 0.08 | 1.6 |
| 8 | Agent Ergonomics | 0.0 | 1.0 | 0.5 | 0.06 | 0.3 |

TypeScript weight (0.10) redistributed per shell-project rules: Test +0.04, Security +0.03, Makefile +0.03.

---

## Top 5 Recommendations

### 1. Create AGENTS.md (Documentation +3pts, Ergonomics +2pts weighted)

Single highest-leverage improvement. No canonical agent onboarding doc exists.
A new agent must reverse-engineer the stack from README + Makefile + scattered docs.

Recommended content:
- **Stack:** Kind cluster + Flux Operator + Envoy Gateway + Dex OIDC + React/Vite SPA + FastAPI + Go tools + BATS + Playwright
- **Command surface:** `make up && make demo-signalloom-up`, `make test`, `make acceptance-test`, per-app targets
- **Test matrix:** BATS (30 files), Playwright (8 browser tests), Go test (proof-helper, demo-console), pytest (FastAPI contracts)
- **Pitfalls:** runner oversubscription, Zot cache persistence, `.env` secret management, `imagePullPolicy: IfNotPresent` with mutable tags
- **Worktrees:** canonical home `~/src/.worktrees/<repo>/<branch>/`

### 2. SHA-pin all 20 GitHub Actions + add Dependabot (Security +15pts weighted)

0/20 actions SHA-pinned. All use mutable tags (`@v3`, `@v4`, `@v5`, `@v6`).
4 use `@main` branch refs (controlplaneio-fluxcd/distribution) -- highest supply-chain risk.

Fix: pin every `uses:` to full 40-char SHA with `# vX.Y.Z` comment.
Add `.github/dependabot.yml` with `package-ecosystem: github-actions`.
Add `permissions: contents: read` to `e2e-local.yaml` (currently has no permissions block).

### 3. Digest-pin Docker base images (Security +3pts weighted)

15 FROM statements across 8 Dockerfiles use mutable tags:
- `golang:1.25-alpine`, `python:3.12-slim`, `python:3.12-alpine`
- `node:22-alpine`, `node:trixie-slim`, `alpine:3.19`
- `gcr.io/distroless/static-debian12:nonroot`, `nginxinc/nginx-unprivileged:1.27-alpine`

Pin each to `@sha256:...` digest.

### 4. Add `.pre-commit-config.yaml` with shellcheck + hadolint + trufflehog (Security +5pts weighted)

The repo is shell-heavy (scripts/, agent/harness.sh) with no local lint gate.
Add `.shellcheckrc` to codify dialect and exclusions.

### 5. Add `make lint`, `make install`, `make test-smoke` targets (Makefile +3pts weighted)

- `lint`: shellcheck across scripts/, hadolint Dockerfiles, eslint dashboard
- `install`: wrap `./scripts/setup.sh`
- `test-smoke`: fast structural subset (syntax checks, contract validation, <30s)

---

## Detailed Findings

### 1. Documentation (Final: 1.9/10)

| Check | Status | Finding |
|-------|--------|---------|
| README.md | PASS | Excellent: prerequisites, quickstart, Mermaid architecture, repo layout table, CI workflow matrix, VEX demo walkthrough. 267+ lines |
| SPEC.md | FAIL | Missing -- no decision log, changelog, or open questions |
| AGENTS.md | FAIL | Missing -- agents cannot self-onboard |
| DESIGN.md | FAIL | Missing -- UI dashboard exists (37+ TSX/TS source files in dashboard-signalloom) |
| DEBUGGING.md | FAIL | Missing (TESTING.md partially covers Playwright diagnostics) |
| SECURITY-REVIEW.md | FAIL | Missing (security-validation-errata.md exists separately) |

README quality is genuinely strong. The gap is entirely in agent/developer onboarding docs.

### 2. Test Architecture (Final: 5.5/10)

| Check | Status | Finding |
|-------|--------|---------|
| Test directory | PASS | 30 test files found |
| Unit tests (Go) | PASS | httptest-based, error paths (unknown service rejection), table-driven |
| Unit tests (Python) | PASS | Contract validation, schema assertions, error paths |
| Integration tests (BATS) | PASS | Runtime tests: NetworkPolicy, egress denial, probe verification, unauthorised persistence access |
| E2E (Playwright) | PASS | 8 browser acceptance tests: Grafana, Archivista, SignalLoom FE, Olly portal. Trace/screenshot/video retention |
| Runner diversity | PASS | 4 runners: BATS, Playwright, Go test, pytest |
| Test names | PASS | Behavioural: "TEST-1 NetworkPolicy blocks unauthorised persistence access" |
| Unhappy paths | PASS | Egress denied, unknown service, policy negatives, failure continuation |
| Assertion variety | PASS | Status codes, string matching, JSON unmarshalling, kubectl wait, grep patterns |
| LIVE_TESTS gate | FAIL | No env-var gate -- cluster tests run unconditionally |
| Parallel execution | FAIL | No parallel config in any runner |
| Serial/debug fallback | FAIL | No `test-serial` target |
| Targeted selection | FAIL | No documented file/test-name selection in Makefile |

### 3. Security & Static Analysis (Final: 3.0/10)

| Check | Status | Finding |
|-------|--------|---------|
| .gitignore | PASS | Covers .keys/, .env, vex/out/, .cache/zot/, __pycache__ |
| Actions SHA pinning | FAIL | 0/20 SHA-pinned; all mutable tags |
| Actions @main refs | FAIL | 4x `controlplaneio-fluxcd/distribution/actions/*@main` |
| Workflow permissions | PARTIAL | 3/5 declare least-privilege; `e2e-local` has none |
| Pre-commit | FAIL | No `.pre-commit-config.yaml` |
| .shellcheckrc | FAIL | Missing despite heavy shell usage |
| .semgrepignore | FAIL | Missing |
| Docker digest pinning | FAIL | 0/15 FROM statements use @sha256 |
| Harden-Runner | FAIL | No egress control in any workflow |
| Dependabot | FAIL | No `.github/dependabot.yml` |
| Install cooldown | FAIL | No bunfig.toml minimumReleaseAge |
| Cosign signing | PASS | push-images, push-artifacts, release-artifacts all cosign-sign |
| SBOM + provenance | PASS | push-images: `sbom: true, provenance: true` |
| CI test gate | PASS | e2e-local: `make attested-test`, olly-test, vex-demo |
| CI security gate | PASS | Witness attestation, Kyverno admission demo |
| Trivy scan | WARN | 4 HIGH: CVE-2026-56852 (golang.org/x/text x2), CVE-2026-32597 + CVE-2026-48526 (PyJWT x2) |
| Semgrep rules | WARN | 73 findings (169 severity-weighted) from agentic preflight custom rules |

### 4. Makefile & Build (Final: 5.8/10)

| Check | Status | Finding |
|-------|--------|---------|
| Makefile exists | PASS | Well-structured, 40+ targets, self-documenting `##` pattern |
| `make test` | PASS | Runs BATS e2e suite |
| `make help` | PASS | Awk-based self-documenting help |
| `make test-unit` | PASS (alias) | Content-backed unit capability exists |
| `make acceptance-test` | PASS | Playwright browser suite with port-forward management |
| `make up/down/teardown` | PASS | Full lifecycle: cluster, registry, signing-keys, push, bootstrap, wait, healthcheck |
| `make test-smoke` | FAIL | Missing |
| `make lint` | FAIL | Missing at root |
| `make install` | FAIL | Missing (setup.sh exists but no Make wrapper) |
| `make clean` | FAIL | Missing |
| `make test-docker` | FAIL | Missing |

### 5. TypeScript Strictness (N/A -- shell project, weight redistributed)

For reference only (not scored):
- Dashboard `tsconfig.json`: `strict: true` but missing `noUncheckedIndexedAccess`
- Acceptance `tsconfig.json`: `strict: true` + `noUncheckedIndexedAccess: true` (good)
- No `biome.json`; ESLint configs present
- 37+ TS/TSX source files in dashboard

### 6. Dependency Management (Final: 3.5/10)

| Check | Status | Finding |
|-------|--------|---------|
| No package-lock.json | PASS | Clean bun-only policy |
| Lockfile coverage | FAIL | 1/3 package.json manifests have bun.lock |
| bunfig.toml cooldown | FAIL | No install cooldown configured |
| bun audit | PASS | 0 advisories |
| SBOM generation | FAIL | No CI SBOM for dependency manifests |
| `type: module` | FAIL | Missing in root package.json |

### 7. Operational Readiness (Final: 1.9/10)

| Check | Status | Finding |
|-------|--------|---------|
| VERSION | FAIL | Missing |
| LICENSE | FAIL | Missing |
| Conventional commits | FAIL | 20/105 recent commits (19%) follow conventional format |
| CODEOWNERS | FAIL | Missing |
| CI/CD workflows | PASS | 5 GitHub Actions workflows |
| State ledgers | FAIL | None |

### 8. Agent Ergonomics (Final: 0.5/10)

| Check | Status | Finding |
|-------|--------|---------|
| AGENTS.md | FAIL | Missing -- canonical agent onboarding doc |
| .editorconfig | FAIL | Missing |
| DESIGN.md | FAIL | Missing (UI dashboard present) |
| Worktree-safe config | N/A | No issues detected |

---

## Trivy Vulnerability Summary

| CVE | Severity | Package | Version |
|-----|----------|---------|---------|
| CVE-2026-56852 | HIGH | golang.org/x/text | v0.37.0 |
| CVE-2026-56852 | HIGH | golang.org/x/text | v0.24.0 |
| CVE-2026-32597 | HIGH | PyJWT | 2.10.1 |
| CVE-2026-48526 | HIGH | PyJWT | 2.10.1 |

---

## Projected Score After Top 5 Fixes

Implementing the top 5 recommendations would lift the score to approximately **58-62/100** (Needs Work / borderline Significant Gaps). Adding VERSION, LICENSE, CODEOWNERS, conventional commit enforcement, and dashboard `noUncheckedIndexedAccess` would push toward **70-75** (Production Ready).

## Grade Scale

| Range | Grade |
|-------|-------|
| 90-100 | Gold Standard |
| 75-89 | Production Ready |
| 60-74 | Needs Work |
| 40-59 | Significant Gaps |
| 0-39 | **Not Agent-Ready** (current) |
