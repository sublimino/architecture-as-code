---
created: 2026-09-28
mission: Signal Loom Private Deployment Security Remediation
shortcode: SLSEC
repo: /home/andy/src/cp/osramp-demo
integration: integration/signalloom-sec-remediation-2026q3
base_ref: e75a945f
cadence: "*/5 * * * *"
max_card_minutes: 180
reviewers:
  - "#john-kjell"
  - "#francesco-beltramini"
capabilities:
  - "#cap-security"
  - "#cap-pentest"
  - "#cap-threat-modelling"
  - "#cap-kubernetes"
  - "#cap-secrets"
  - "#cap-networking"
  - "#cap-python"
  - "#cap-devops"
practice:
  - Cyber Resilience & Threat Assurance
  - AI & Data Security
obsidianProject: "1. Projects/2026-09-signalloom-p0-security-hardening/"
parentProposal: "[[Proposal — Flux D2 Agentic Architecture (2026-Q1)]]"
tags:
  - innovation-proposals
  - proposal-2026-q3-slsec-signalloom-security-remediation
aliases:
  - "#proposal-2026-q3-slsec-signalloom-security-remediation"
status: DRAFT — awaiting sign-off. No work has started. No board cards, branches, worktrees, or cron exist.
---
# Proposal — SLSEC Signal Loom Private Deployment Security Remediation (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-09-28) |
| Reviewer & Date: |  |
| Approver & Date: |  |

## Press Release

A blackbox pentest of the running Signal Loom instance (`ftna-signalloom.taild4da3.ts.net`, mirrored on `localhost:5173`) found a **critical unauthenticated broken-access-control flaw**: five EAP routers — including tenant-isolation management — accept create/read/**delete** with no token, leaking Kubernetes isolation manifests and SPIFFE identity records. The fix already exists: it was built, mutation-tested, adversarially reviewed, and **sealed with human sign-off** as mission EAPR on 2026-09-25 (`integration/eapr-v0.1.0`). It was never merged into the branch the live pod was rebuilt from on 2026-09-27, so the running system still ships the vulnerable code.

This mission lands that sealed fix onto the running line, then closes the findings EAPR does not cover — an unthrottled identity token endpoint, four datastores bound to every interface, an unauthenticated attestation GraphQL endpoint, and a complete absence of security response headers. It ends with a permanent CI gate that fails the build if any route ever ships anonymous again, and a repeat of the blackbox pentest as certified proof. It converts a live, human-signed-off-but-undeployed fix into a deployed, re-testable secure baseline.

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [ ] client revenue
- [ ] marketing
- [x] product
- [x] services engineering
- [ ] cost avoidance
- [ ] process efficiency
- [x] operational or regulatory internal

**Key Customers (if relevant):** Internal platform integrity; regulated-finance prospects who security-review Signal Loom before adoption.

|  |  |
| :---- | :---- |
| Our *platform engineering team and regulated prospects* | need the running Signal Loom deployment to hold under adversarial testing |
| Have the problem/opportunity *…* | a pentest found a live Critical BAC plus six lesser issues; the fix for the Critical is sealed but unmerged |
| When *…* | now — the flaws are live on a tailnet-reachable instance rebuilt from a branch that never received the merge |

**Urgency:** Q3 2026, immediate. Serves the existing `2026-09-signalloom-p0-security-hardening` project. Evidence baseline: `~/.claude/PAI/MEMORY/WORK/20260928-signalloom-blackbox-pentest/ISA.md`.

## Scope Summary

Technology Readiness Level: **4 (Production)** — hardens a running platform; the Critical fix is already production-sealed and needs integration, not R&D.

### Vision

Every EAP route rejects anonymous callers; tenant is derived from the verified principal, never a path segment or header. The identity endpoint is throttled. Datastores and attestation services are unreachable off-host. Every response carries a security-header set. A CI gate makes an unauthenticated regression impossible to merge. A repeat blackbox pentest returns zero Critical and zero High findings.

### In Scope

- Merge and deploy the sealed EAPR router-auth chain onto the running line (F1 Critical, F5).
- Repair the current tests that assert unauthenticated success as correct.
- Rate-limit the Dex token endpoint and shorten token lifetime; stage ROPC to Auth Code + PKCE (F2).
- Bind datastores off `0.0.0.0`; gate or internalise Archivista GraphQL; disable GraphiQL (F3, F4).
- Add security headers and suppress version banners at the dashboard nginx front (F6, F7).
- Add a CI unauthenticated-access sweep gate; rebuild, redeploy, and blackbox re-test.

### Out of Scope

- Full source audit beyond the pentest findings and the bare-mounted-router class.
- The adjacent Express messaging bridge on `:3000` (personal tooling, not the platform).
- `NOT_AUDIT_WORTHY` / `AUDIT_DECISION_OWED` audit-emission debt (EAPR-P2-2's ledger, tracked separately).
- Production/GCP edge hardening beyond parity (tracked under the OSRAMP GCP terraform projects).

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Unauthenticated-reachable EAP routers | 5 (tenant_isolation, environment_routing, scenario_seeding, environment_lifecycle, webhook_triggers) | 0 | anon_sweep.py + live probe |
| Open Critical / High pentest findings | 1 / 1 | 0 / 0 | Certified blackbox re-test |
| Datastores bound to `0.0.0.0` | 4 (mysql, minio, archivista, postgres) | 0 | `ss -lnt` / nmap |
| Security response headers present | 0 / 6 | 6 / 6 | nginx-security-headers.bats + live header dump |
| Dex token-endpoint brute-force protection | none (10 attempts, 0×429) | enforced (429 after threshold) | Repeated-attempt probe |
| CI gate blocking unauthenticated regressions | 0 | 1 (fails build) | CI run against regression fixture |
| Live pod ships the sealed EAPR fix | no (rev 61, wrong branch) | yes | `git merge-base --is-ancestor` + redeploy verify |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| Five EAP routers reject anonymous callers | pytest TestClient (JWT-forgery pattern) + `anon_sweep.py` | Signal Loom platform engineering |
| Blackbox re-test of all seven findings, CVSS-scored | Purple-team re-run vs the pentest ISA baseline | Cyber Resilience & Threat Assurance practice |
| Tenant derived from principal, not path/header (IDOR) | Multi-principal pytest cross-tenant probes | AI & Data Security practice |
| Security headers + rate-limit present | `nginx-security-headers.bats` + live curl header/429 checks | Signal Loom platform engineering |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| FastAPI `Depends(authenticated_principal/tenant)` (`api_compat.py:1492/1522`) | Uniform route auth + tenant binding | Already the platform's mechanism; EAPR applies it at the mount |
| `eap_tenancy.py` ownership registry + `IdentityHeaderStripMiddleware` | Tenant ownership + strip spoofable identity headers | Delivered by EAPR-P2-1 |
| nginx `add_header`, `server_tokens off`, `limit_req` | Security headers, banner suppression, rate limiting | docs nginx.conf already sets headers — copy the pattern |
| Dex Auth Code + PKCE | Replace ROPC/public-client password grant | Dex supports it; `dex.yaml` change |
| K8s / docker bind + gated proxy | Loopback/internal binding for datastores & Archivista | `kind` API already binds loopback-only |
| pytest / bats + `vm-pipeline.sh` | Regression gate and re-test | Extends existing offline + cluster suites |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Backend + five routers | `d2-signalloom/apps/fe-signalloom/src/` | tenant_isolation.py:329, environment_routing.py:518, scenario_seeding.py:327, environment_lifecycle.py:399, webhook_triggers.py:294 |
| Sealed fix | `integration/eapr-v0.1.0` tip `e3f516b1`; commit `e5540b2c` (EAPR-P2-1) | Not an ancestor of HEAD `e75a945f`; merge required |
| Dashboard nginx | `d2-signalloom/apps/dashboard-signalloom/nginx.conf` | No headers, no server_tokens off, no limit_req |
| Dex config | `d2-signalloom/infra/inf-signalloom/base/dex.yaml` | Public client, enablePasswordDB:true |
| Live deploy | kind cluster `osramp`, ns `fe-signalloom`, `kubectl port-forward svc/dashboard-signalloom 5173:8080` | Rebuild: `make demo-signalloom-up` → `scripts/signalloom-local.sh up` |
| Pentest evidence | `~/.claude/PAI/MEMORY/WORK/20260928-signalloom-blackbox-pentest/ISA.md` | 34 ISCs, per-finding transcripts |

#### Security and Risk

**Threat model for this deliverable:**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Spoofing — no identity to manage tenant boundaries | Create/read/delete tenant config unauth; manifest + SPIFFE disclosure | Land EAPR: `Depends(authenticated_principal)` at every mount; deny-by-default |
| Tampering / DoS — unauth DELETE tears down boundaries | Destructive removal of isolation state | Route auth + tenant ownership registry; audit decision |
| Info disclosure — manifests, SPIFFE IDs, transit key paths, banners | Recon gift to attacker targeting the identity/crypto layer | Gate routes; suppress banners; disable GraphiQL |
| Brute force — unthrottled ROPC on a public client | Online credential stuffing against real users | Rate-limit; migrate to Auth Code + PKCE |
| Lateral movement — datastores on `0.0.0.0` | Larger blast radius from any interface / the tailnet | Bind loopback/internal; gate Archivista |
| Regression — the fix un-merges again | The exact failure that produced this pentest | CI gate + structural mount assertion + anon_sweep in the pipeline |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| The Critical fix is already built, tested, and human-sealed | It sits on a branch 207 commits diverged from HEAD; merge conflicts expected in five files |
| The correct auth + header patterns already exist to copy | Current tests assert unauth success as correct — they must be repaired, not trusted |

| Opportunities | Threats |
| :---- | :---- |
| A deployed, re-testable secure baseline to show regulated prospects | A prospect's security review finds the Critical before it lands |
| A permanent CI gate ends the un-merge failure mode | Merging the whole EAPR chain risks pulling adjacent unfinished debt |

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: Land the sealed EAPR router-auth chain; repair auth-asserting tests (F1, F5) |  |  |  |  | #cap-security #cap-python #cap-devops |
| M2: Dex token rate-limit + shorter TTL; stage PKCE (F2) |  |  |  |  | #cap-secrets #cap-networking #cap-security |
| M3: Datastore binding + Archivista GraphQL gating; disable GraphiQL (F3, F4) |  |  |  |  | #cap-kubernetes #cap-networking #cap-security |
| M4: Security headers + server_tokens off at dashboard nginx (F6, F7) |  |  |  |  | #cap-security #cap-blue-team |
| Mid-project review: demo of progress, evaluation of further milestones, raising of current and new risks | 0.25 | 2 | 0.5 |  | #cap-project-management |
| M5: CI unauth-sweep gate; rebuild, redeploy, blackbox re-test & certification |  |  |  |  | #cap-pentest #cap-purple-team #cap-testing-pyramid |
| Signoff |  |  |  |  | #cap-security |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:** all five EAP routers reject anonymous; 0 Critical / 0 High on a certified re-test; datastores off `0.0.0.0`; Archivista GraphQL gated; 6/6 headers; `/dex/token` rate-limited; CI gate fails on a regression fixture; the running pod rebuilt from the merged fix.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | Cyber Resilience & Threat Assurance practice lead ([[John Kjell]]) |
| Responsible | Signal Loom platform engineering team |
| Consulted | AI & Data Security practice ([[Vicente Herrera]]); Head of Technical Solutions ([[Francesco Beltramini]]) |
| Informed | [Andrew Martin](mailto:andy@control-plane.io) [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

## Mission Parameters (Auto Kanban contract)

| Parameter | Value |
| :---- | :---- |
| Repository realpath | `/home/andy/src/cp/osramp-demo` |
| Shortcode | `SLSEC` |
| Integration branch | `integration/signalloom-sec-remediation-2026q3` (created post-signoff, in a Governor worktree, off `e75a945f`) |
| Base ref | `e75a945f` (HEAD of `feat/signal-loop-and-bootstrap-refactor`) |
| Cadence | `*/5 * * * *` (Europe/London) |
| Wall-clock ceiling | ≤180 min per card |
| No work started | No board cards, branches, worktrees, or cron exist yet |

**Approved acceptance commands (exact):**

1. `make test-all-offline`
2. `cd d2-signalloom/apps/fe-signalloom/src && UV_CONFIG_FILE=/dev/null uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests -q --disable-warnings`
3. `bats d2-signalloom/test/authz-suite-liveness.bats d2-signalloom/test/api-route-liveness.bats`
4. `python3 scripts/eap/anon_sweep.py`  (durable EAP anonymous-route sweep, from EAPR)
5. `make demo-signalloom-up && SIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up`  (rebuild + redeploy)
6. Blackbox re-verify: repeat pentest ISC-8–12 unauthenticated probes against `http://localhost:5173/api/v1/eap/tenants*`

## Finances

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| None anticipated (existing infra and team) | £0 | One Off | Must-Have |

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-09-28 | AJM | Phase 1 is a governed merge of the sealed EAPR chain, not a re-implementation | The fix is built, tested, and human-sealed on `integration/eapr-v0.1.0`; only the merge to the running line is missing | Removes re-implementation risk; adds conflict-resolution risk across 207 divergent commits |
| 2026-09-28 | AJM | Enhancement under Flux D2 / Signal Loom line, routed to `2026-09-signalloom-p0-security-hardening` | Bounded remediation inside an existing platform | Re-route via `obsidian-mv` if Innovation-tier preferred |

## Appendix

### Spec: Shared Patterns

Living architectural constitution for the mission. `P<N>-PRE` and `P<N>-GOV` cards inspect and extend this.

- **Auth is applied at the mount, not per-handler.** Every router mounts with `app.include_router(router, dependencies=[Depends(api_compat.authenticated_principal)])`. Per-handler opt-in is the root cause of this pentest — routers generated from cards that never mention auth ship anonymous. Reference: `api_compat.py:7187` (compat router mounted with `Depends(enforce_strict_operator_tenant)`).
- **Tenant derives from the verified principal, never from a path segment, request body, or client header.** Use `Depends(authenticated_tenant)` (`api_compat.py:1522`); resolve ownership through the `eap_tenancy.py` registry (`claim_or_403` / `require_owned_or_404` / `owned_hashes`, from EAPR-P2-1).
- **Spoofable identity headers are stripped at ingress.** `IdentityHeaderStripMiddleware` removes `X-SPIFFE-ID`, `X-Tenant-Id`, and underscore spellings as the outermost middleware (EAPR-P2-1, commit `7363075d`).
- **Auth dependencies (reuse, do not re-invent):** `authenticated_principal` `api_compat.py:1492`; `authenticated_tenant` `api_compat.py:1522`; `enforce_strict_operator_tenant` `operator_identity.py:370` (operator-only routes: reaper/pause/metrics).
- **Test runner:** `cd d2-signalloom/apps/fe-signalloom/src && UV_CONFIG_FILE=/dev/null uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests -q`. `-n auto` is baked into `pytest.ini` (needs pytest-xdist); pin `--python 3.12`; some suites need `-p no:libtmux`.
- **Negative-auth test pattern:** in-process TestClient with the JWT-forgery fixture from `test_adversarial_idor.py:29-98` (RSA keypair, monkeypatch `api_compat._jwk_client`); the negative case is simply omitting the `headers=` kwarg. New `test_*.py` in `apps/fe-signalloom/src/tests/` is auto-collected by CI Stage 2.
- **Anti-pattern (must not recur):** a test that asserts an unauthenticated request succeeds (current `test_tenant_isolation.py:129-183`, `test_environment_lifecycle.py:152-186` assert `201` with no token). These are repaired to assert `401/403`.
- **Merge, do not rewrite:** the fix is `integration/eapr-v0.1.0` (`e3f516b1`). Restore `test_eap_default_deny.py` and `test_eap_forged_headers.py`; repoint `authz-suite-liveness.bats` at the restored `ATTACK_MANIFEST`.

### Spec: Capability Plan

| Logical ID | Skills Required | Agent Role | Size Band | Ceiling |
| :--- | :--- | :--- | :---: | :---: |
| `P0` | `#cap-python`, `#cap-devops` | `daily` | `S` | 60m |
| `P1-PRE` | `#cap-security`, `#cap-devops`, `#cap-threat-modelling` | `daily` | `S` | 90m |
| `P1-1` | `#cap-security`, `#cap-python`, `#cap-devops` | `deep` | `L` | 180m |
| `P1-2` | `#cap-python`, `#cap-testing-pyramid`, `#cap-security` | `daily` | `M` | 120m |
| `P1-GOV` | `#cap-security`, `#cap-purple-team` | `deep` | `M` | 150m |
| `P2-PRE` | `#cap-secrets`, `#cap-threat-modelling` | `daily` | `S` | 60m |
| `P2-1` | `#cap-secrets`, `#cap-networking`, `#cap-security` | `daily` | `M` | 150m |
| `P2-GOV` | `#cap-security`, `#cap-secrets` | `deep` | `M` | 120m |
| `P3-PRE` | `#cap-kubernetes`, `#cap-networking` | `daily` | `S` | 60m |
| `P3-1` | `#cap-kubernetes`, `#cap-networking`, `#cap-security` | `daily` | `M` | 150m |
| `P3-GOV` | `#cap-kubernetes`, `#cap-security` | `deep` | `M` | 120m |
| `P4-PRE` | `#cap-security`, `#cap-networking` | `daily` | `S` | 45m |
| `P4-1` | `#cap-security`, `#cap-blue-team`, `#cap-networking` | `daily` | `M` | 120m |
| `P4-GOV` | `#cap-security`, `#cap-blue-team` | `daily` | `S` | 90m |
| `P5-PRE` | `#cap-pentest`, `#cap-testing-pyramid` | `daily` | `S` | 60m |
| `P5-1` | `#cap-testing-pyramid`, `#cap-devops`, `#cap-security` | `daily` | `M` | 150m |
| `P5-2` | `#cap-pentest`, `#cap-purple-team`, `#cap-devops` | `deep` | `L` | 180m |
| `P5-GOV` | `#cap-pentest`, `#cap-threat-modelling`, `#cap-security` | `deep` | `L` | 180m |

### Spec: Work Decomposition

| Logical ID | Role | Summary | Dependencies | Tests | Size | Agent | Result | Cost | Rerun | WallClock | Model | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :---: | :---: | :--- | :---: | :---: | :---: | :--- | :----- | :------ | :--- |
| `P0` | implementation | Establish remediation baseline: verify the test runner and `make demo-signalloom-up` build path work; capture current-state failing probes (unauth 200/201 on the five routers) as the regression baseline | None | `anon_sweep` baseline capture; runner smoke: pytest collects `tests` | S | daily | Pending — not started |  |  |  |  |  |  |  |
| `P1-PRE` | preflight | Audit the EAPR chain (`integration/eapr-v0.1.0` `e3f516b1`, EAPR-P2-1 `e5540b2c`) vs HEAD; enumerate the five bare mounts; choose merge vs cherry-pick and the exact ref set; record the conflict surface (five router files, 207 divergent commits); extend Shared Patterns — Phase 1 | P0 | Confirm `git merge-base --is-ancestor e5540b2c HEAD` is false; list conflicting files | S | daily | Pending — not started |  |  |  |  |  |  |  |
| `P1-1` | implementation | Merge the sealed EAPR router-auth chain onto the integration branch; resolve conflicts so all five routers mount behind `Depends(authenticated_principal)` with tenant binding; restore `eap_tenancy.py` and `IdentityHeaderStripMiddleware`; operator-only gating on reaper/pause/metrics | P1-PRE | `test_eap_default_deny.py`, `test_eap_forged_headers.py` pass; `anon_sweep.py` = 0 anonymous | L | deep | Pending — not started |  |  |  |  |  |  |  |
| `P1-2` | implementation | Repair tests that assert unauth success: rewrite `test_tenant_isolation.py` / `test_environment_lifecycle.py` to expect 401/403 unauthenticated; add positive authed controls; repoint `authz-suite-liveness.bats` at the restored `ATTACK_MANIFEST` | P1-PRE | `authz-suite-liveness.bats` 3/3 ok; repaired pytest suites green | M | daily | Pending — not started |  |  |  |  |  |  |  |
| `P1-GOV` | governor | Certify Phase 1: merge P1-1+P1-2 to the integration branch; run offline gate + EAP suites + `anon_sweep.py`; verify all five routers reject anonymous; write errata | P1-1, P1-2 | `make test-all-offline` green; `anon_sweep.py` = 0 | M | deep | Pending — not started |  |  |  |  |  |  |  |
| `P2-PRE` | preflight | Audit Dex config (`dex.yaml`: public client, enablePasswordDB) and the nginx `/dex/` proxy; choose rate-limit layer (nginx `limit_req` vs edge) and PKCE feasibility within ceiling | P1-GOV | Locate `/dex/` proxy block; confirm `limit_req` absent today | S | daily | Pending — not started |  |  |  |  |  |  |  |
| `P2-1` | implementation | Add `limit_req` throttling to the `/dex/token` path (keyed on username+IP); shorten `id_token` TTL; stage/implement Auth Code + PKCE for the SPA client and disable ROPC where feasible | P2-PRE | bats/curl: 429 after threshold on `/dex/token`; SPA login works via PKCE | M | daily | Pending — not started |  |  |  |  |  |  |  |
| `P2-GOV` | governor | Certify Phase 2: merge; verify rate-limit and token-TTL live; confirm no login regression | P2-1 | Live 429 probe; login smoke | M | deep | Pending — not started |  |  |  |  |  |  |  |
| `P3-PRE` | preflight | Inventory the actual `0.0.0.0` bindings (docker archivista stack: mysql/minio/archivista/postgres; K8s containerPorts) and the Archivista GraphQL/GraphiQL exposure; choose loopback vs docker-internal vs gated-proxy per service | P1-GOV | `ss -lnt` inventory; confirm Archivista `:8082/query` unauth today | S | daily | Pending — not started |  |  |  |  |  |  |  |
| `P3-1` | implementation | Bind mysql/minio/archivista/postgres off `0.0.0.0` (loopback or docker-internal); put Archivista GraphQL behind the OIDC/SPIRE-gated proxy or internal-only; disable the GraphiQL playground | P3-PRE | `ss -lnt` shows 0 datastores on `0.0.0.0`; Archivista `:8082/query` → 401 | M | daily | Pending — not started |  |  |  |  |  |  |  |
| `P3-GOV` | governor | Certify Phase 3: verify bindings and Archivista gating; confirm intra-cluster consumers still reach services | P3-1 | Binding + reachability checks | M | deep | Pending — not started |  |  |  |  |  |  |  |
| `P4-PRE` | preflight | Diff dashboard `nginx.conf` against the docs `nginx.conf` header set; enumerate the six headers to add and `server_tokens off`; confirm the `/supercred-api/` read-only exception stays intact | P1-GOV | Header gap list vs docs conf | S | daily | Pending — not started |  |  |  |  |  |  |  |
| `P4-1` | implementation | Add CSP, X-Frame-Options, X-Content-Type-Options, HSTS, Referrer-Policy, Permissions-Policy and `server_tokens off` to dashboard `nginx.conf`; add `nginx-security-headers.bats` (static parse + live check) | P4-PRE | `nginx-security-headers.bats` green; live dump shows 6/6, no version banner | M | daily | Pending — not started |  |  |  |  |  |  |  |
| `P4-GOV` | governor | Certify Phase 4: verify headers live and no banner leak; no SPA regression | P4-1 | Live header dump | S | daily | Pending — not started |  |  |  |  |  |  |  |
| `P5-PRE` | preflight | Design the CI unauth-sweep gate: where it wires in `scripts/ci/vm-pipeline.sh` (Stage 2 pytest, Stage 7 bats); design the regression fixture that must fail the build | P1-GOV, P2-GOV, P3-GOV, P4-GOV | Identify wiring points; fixture design | S | daily | Pending — not started |  |  |  |  |  |  |  |
| `P5-1` | implementation | Add the unauthenticated-access sweep pytest (auto-collected Stage 2); extend `api-route-liveness.bats` unauth loop to the EAP routers; wire `adversarial-boundaries.bats` into `vm-pipeline.sh`; prove the gate fails on a regression fixture | P5-PRE | Gate fails on injected unauth regression; passes clean | M | daily | Pending — not started |  |  |  |  |  |  |  |
| `P5-2` | implementation | Rebuild + redeploy the running instance (`make demo-signalloom-up` → `signalloom-local.sh up`); blackbox re-test all seven findings (repeat pentest ISCs); capture certified evidence | P5-1 | Redeploy verified; ISC-8–12 unauth probes → 401/403; 0 Critical/High | L | deep | Pending — not started |  |  |  |  |  |  |  |
| `P5-GOV` | governor | Final mission certification: full offline gate + EAP suites + live re-test evidence; produce the sign-off evidence ledger | P5-1, P5-2 | `make test-all-offline` green; certified re-test attached | L | deep | Pending — not started |  |  |  |  |  |  |  |

### Spec: Errata

*Runtime outcome ledger. Empty at bootstrap — no work has started. Each card appends a `#### Errata — SLSEC-<ID> (date)` block on completion.*
