# SLEA-P4-GOV — Mission Certification Report: On-Demand EAP Environment Routing

**Verdict:** **NOT CERTIFIED — release NOT sealed** (`status=fail`)
**Recorded:** 2026-09-23 03:35:39+01:00
**Integration ref:** `refs/heads/integration/slea-v0.1.0` at `8629b5f81e6ab2488dd7c4b4896855de8c7387f0`
**Governor worktree:** `/home/andy/src/.worktrees/osramp-demo/slea-v0.1.0/governor`

This report replaces the unevidenced PASS certification that existed only on dangling
commit `9fadbf46d54360eb44c6b8ae657644c927b124e3` (`docs/signalloom/slea-p4-gov-review.md`,
never on any branch). That document is not reproduced here: it states a mesh URL of
`https://sl-eap-6f82ad81.tailscale.net` and an external FQDN of `sl-eap-6f82ad81.signalloom.com`,
and neither matches the code. The code emits `https://sl-eap-6f82ad81.tailscale` and
`https://sl-eap-6f82ad81.ts.net`.

## 1. Why the release is not sealed

1. **The environment API has no authentication.** It is a critical finding. Every other probed `/api/*`
   route returns `401` without credentials. `/api/v1/environments/*` returns `201`/`200`.
   An anonymous caller can provision, list, extend and tear down environments, and can read
   every `company_name ↔ customer_hash` pairing. That defeats the purpose of the salt.
2. **Two regression tests fail in the full fe-signalloom suite** (`2 failed, 1474 passed, 83 skipped`):
   - `test_audit_provenance.py::test_every_mutating_route_makes_an_audit_decision`: 4 SLEA
     mutating routes neither audit nor declare `NOT_AUDIT_WORTHY`.
   - `test_tenant_isolation.py::test_the_route_sweep_covers_every_authenticated_api_route`: 6 SLEA
     routes are in neither `DB_ROUTES` nor `NOT_DATABASE_BACKED`.
3. **The salt is hard-coded in git-tracked files** (`environment_routing.py:24`,
   `scripts/eap/tailscale-eap-env.sh:12`). The default `signalloom-eap-salt-2026-q3` is public,
   so any 8-hex hash reverses to a company name by dictionary lookup. The canonical vector
   `kurasi → 6f82ad81` holds **only** under this public default.
4. **The board's "done" state is unevidenced.** `kanban-check doctor` reports UNHEALTHY with
   13 zero-output `done` cards. Only one SLEA commit (`8629b5f8`) exists on the integration
   branch. The artifacts that cards P2–P4 claim are absent (§3).

## 2. Prior-work verification table

| Artifact | Probe | Result |
| :-- | :-- | :-- |
| `scripts/eap/tailscale-eap-env.sh` | `wc -l`; `rg '^[a-z_]+\(\)'` | 272 lines, 11 functions — **VERIFIED present** |
| `fe-signalloom/src/environment_routing.py` | `wc -l`; `rg install_environment_routing_api main.py` | 520 lines, mounted at `main.py:15,42` — **VERIFIED** |
| `src/tests/test_environment_routing.py` | `pytest -v` | **15 passed**, 0 failed |
| `scripts/eap/test_tailscale_eap_env.sh` | `bash …` | **15 passed**, 0 failed (all mock-mode, see §4) |
| `tests/test_kurasi_eap_lifecycle.py` | `fd` over worktree | **ABSENT** — never on branch |
| `tests/test_environment_api.py` | `fd` over worktree | **ABSENT** — API tests live inside `test_environment_routing.py` |
| `scripts/eap/test_reconcile_eap_ingress.sh` | `ls` | **ABSENT** — no reconciler exists |
| Dex origin lease / namespace bootstrapper / teardown GC (P3-2, P4-1) | `rg -n 'dex\|namespace\|subprocess' environment_routing.py` | **ABSENT** — only `eap-httproute-template.yaml` (34 lines) |
| Full fe-signalloom suite | `uv run … pytest tests -q` | **2 failed**, 1474 passed, 83 skipped |
| `kanban-check doctor --shortcode SLEA` | exit code | **rc=1 UNHEALTHY** (13 zero-output cards; P4-GOV oscillation) |
| Canonical kurasi vector | Python `sha256("signalloom-eap-salt-2026-q3:kurasi")[:8]`; `tailscale-eap-env.sh urls '  KuRaSi '` | `6f82ad81`, `https://sl-eap-6f82ad81.tailscale` — **VERIFIED** in both layers |
| Salt leakage in telemetry | `rg 'log\|print\|salt' environment_routing.py` | Salt never logged or returned — **PASS**; but `company_name` logged at INFO (`:320`) |

## 3. Phase-constitution compliance

| Pattern | Result | Evidence |
| :-- | :-- | :-- |
| Hashing invariance (`strip().lower()`) | PASS | tests + shell `urls '  KuRaSi '` → `6f82ad81` |
| Error safety (no silent Tailscale failure) | **FAIL** | `tailscale-eap-env.sh:16-21` silently switches to mock when the binary is absent |
| Idempotence (return existing + refresh heartbeat) | **FAIL** | registry raises `409 CONFLICT` (`environment_routing.py:296`); no heartbeat field |
| Clean reverse-order teardown | **FAIL** | teardown flips in-memory state only (`:388-394`); no route cut, Dex release, node de-registration or namespace deletion |

Additional defects:

- The registry is an in-memory `EnvironmentRegistry` (`:280`), so all environments are lost on pod restart.
- In `tailscale-eap-env.sh` `calc_hash`, the `python3` fallback interpolates the company name into
  Python source (`b'$payload'`), which allows code injection. It also never assigns `full_hash`,
  so the function returns an empty hash. This path runs only when neither `sha256sum` nor `shasum` is installed.

## 4. Real-mesh provisioning

The `tailscale` 1.98.10 binary and `tailscaled` are present on this host. The shell suite
therefore passes only because it forces `TAILSCALE_MOCK=1`, and every provision, serve and
teardown assertion is a **mocked, labelled** run. A live `tailscale up` would register a real node on
the principal's tailnet. That is an outward-facing action not named in the plan, so this governor did not run it.
Real-mesh provisioning remains **unproven**.

## 5. Release-readiness checklist

| Criterion | Status |
| :-- | :-- |
| 100% green across Python, shell and acceptance suites | **FAIL** (2 failures; acceptance suite absent) |
| kanban doctor clean | **FAIL** (rc=1) |
| kurasi vector `6f82ad81` → `https://sl-eap-6f82ad81.tailscale` | PASS (public-default salt only) |
| Salt loaded securely, never in telemetry | PARTIAL (not logged, but hard-coded default in git) |
| Threat model: tenant isolation / network boundary | **FAIL** (unauthenticated API; not in tenant sweep) |
| Docs complete in `docs/signalloom/` | **FAIL** (no SLEA architecture or ops docs exist) |
| Working tree clean | PASS (only this report added) |

Deliverables that presuppose a sealed release are deliberately **not** produced: the release announcement,
SRE hand-off, architecture summary, post-review and merge seal. Writing them would certify a release that fails its own gate.

## 6. Remediation required before re-certification

1. Add the platform-admin auth dependency to the `/api/v1/environments` router and a negative test (401 anonymous).
2. Classify the 6 routes in `test_tenant_isolation.py` and add an audit write, or a justified
   `NOT_AUDIT_WORTHY` entry, for the 4 mutating routes.
3. Remove the hard-coded salt default. Fail closed if `SIGNAL_LOOM_EAP_SALT` is unset, and keep the kurasi vector as a test-only fixture salt.
4. Make provision idempotent (return existing + heartbeat) and implement reverse-order teardown against real infra, or re-scope the proposal.
5. Remove the silent auto-mock fallback and the injectable `python3` hash fallback.
6. Re-run P2–P4 cards whose output is zero, author the missing lifecycle, API and reconciler suites, then re-run this governor.
