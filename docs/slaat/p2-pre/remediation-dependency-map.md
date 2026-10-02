# SLAAT-P2-PRE: Remediation dependency map

Links every Phase 1 finding (`ci-evidence/slaat-phase1-consolidated-findings.json`)
to its Phase 2 remediation card, with the positive-control reproduction status
captured by this preflight. All four target cards branch from
`integration/slaat-whole-system-adversarial` @ `7ddc84f0ef76f5c7b4a35c7b7456396ee9f13b78`
(see preflight errata for the base-drift note).

## SLAAT-P2-1 — Ingress Route Protection & Network Microsegmentation

| Finding | Severity | Reproduced | Evidence |
| :--- | :--- | :--- | :--- |
| NET-1 ingress namespace: zero NetworkPolicy, metrics :19001 open | HIGH | yes | `ci-evidence/slaat-p2-pre-repro-network-isolation.json` → `NETPOL-ingress` |
| NET-2 backend namespace: zero NetworkPolicy | MEDIUM | yes | same file → `NETPOL-backend` (fail) |
| NET-3 frontend namespace: zero NetworkPolicy | MEDIUM | yes | same file → `NETPOL-frontend` (fail) |
| NET-4..NET-9 (fe-k8s-afm, cpai, kagent, etc.) | LOW/MEDIUM | yes | same file, 10/32 records fail overall |

Target files confirmed to exist and be writable: per-app `base/networkpolicy.yaml`
manifests exist under `d2-signalloom/apps/*/base/` and `d2-signalloom/infra/*/configs/base/`
(13 files located, sampled `d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml`
confirmed writable). **Open gap:** no `d2-signalloom`-rooted manifest declares
`namespace: backend` or `namespace: frontend` directly — P2-1 will need to locate
or create the owning kustomize base for these two namespaces before patching
(not resolved by this preflight; flagged, not blocking).

## SLAAT-P2-2 — Backend API Auth, Token Expiry & Tenant IDOR

| Finding | Severity | Reproduced | Evidence |
| :--- | :--- | :--- | :--- |
| API-F1 no rate limiting middleware anywhere | MEDIUM | static (code-confirmed, not re-probed live) | `ci-evidence/slaat-p1-2-api-findings.json` |
| API-F2 `cors_allowed_origins` declared, never wired | LOW | static (code-confirmed) | same file |

Target: `d2-signalloom/apps/fe-signalloom/src/` — confirmed writable and
byte-compiles cleanly (`python3 -m compileall`, see Decisions below for the
required cache-path fix). **Blocking toolchain defect found:** two of the
three adversarial pytest modules fail to *collect* —
`tests/test_adversarial_api_security.py` and `tests/test_tenant_authorization_matrix.py`
both raise `ImportError: cannot import name '_IncludedRouter' from 'fastapi.routing'`
(private FastAPI symbol absent from the pinned `fastapi==0.115.6`). Full log:
`docs/slaat/p2-pre/api-pytest-collection.log`. `tests/test_token_adversarial_verification.py`
is unaffected (36/36 pass standalone). This defect predates this preflight
(introduced in `2dbb32e2` on `SLAAT-P1-2`, 2026-10-02 01:32:07+01:00) and must
be fixed before SLAAT-P2-2 can prove its fixes with these two suites, per the
mission's "every fix has an accompanying automated test" rule.

## SLAAT-P2-3 — SPIFFE Workload API & OpenBao Policy Hardening

| Finding | Severity | Reproduced | Evidence |
| :--- | :--- | :--- | :--- |
| SPIFFE-F1 `signalloom-cardvault-agent` / `signalloom-fe-signalloom` issue 768h tokens vs. 5-minute mission cap | **CRITICAL** | **yes, exactly** | `ci-evidence/slaat-p2-pre-repro-spiffe.json` → `SPIFFE-3`, `TTL-signalloom-cardvault-agent`, `TTL-signalloom-fe-signalloom` (`effective_token_ttl_seconds=2764800`) |
| SPIFFE-12 bound-claims glob mismatch (openbao-jwt-bound-claims) | (catalogued under P1-3 dossier; not in the 24-finding consolidated set but reproduced live here) | yes | same file → `SPIFFE-12` |

Root cause confirmed by direct source inspection:
`d2-signalloom/infra/inf-bao/configs/base/openbao-bootstrap.yaml` line 30-33,
`bao write auth/jwt/role/signalloom-fe-signalloom` has no `token_ttl`/
`token_max_ttl` argument, so it inherits the `auth/jwt` mount's
`default_lease_ttl=768h`. File confirmed writable. The equivalent
`signalloom-cardvault-agent` role stanza is in the same file.

## SLAAT-P2-4 — Agent Sandbox Confinement & Landlock LSM Policy

| Finding | Severity | Reproduced | Evidence |
| :--- | :--- | :--- | :--- |
| SENTINEL-F1 deployed eBPF probe is socket-state-only; zero syscall telemetry for process spawning / unshare(CLONE_NEWPID) | HIGH | **yes, exactly** | `ci-evidence/slaat-p2-pre-repro-sentinel-evasion.json` — 9/9 probes pass, including `live.evasion-burst-generates-no-syscall-telemetry` |

Target: `d2-signalloom/apps/signalloom-stun-sentinel` (deployed image's wiring)
and/or `d2-signalloom/apps/stun-sentinel/bpf/sentinel_probe.c` (the fuller,
already-unit-tested syscall tracer that is simply not instantiated by any
`cmd/` entrypoint). Both paths confirmed to exist; `go build ./...` is clean
in the deployed module (see dry-run compile log).

## Toolchain / build-readiness findings outside the four remediation streams

- **`d2-signalloom/apps/dashboard-signalloom`: `bun run build` (`tsc && vite build`) fails, exit 2**,
  ~24 pre-existing TypeScript errors in `src/components/demos/bridge.test.ts`
  (committed `439728c0`, 2026-09-30 02:08:14+01:00) and
  `src/pages/AgentsPage.tsx` (committed `2040d91d`, 2026-09-30 09:15:37+01:00).
  Neither file is in scope for any SLAAT-P1 finding or SLAAT-P2 card; both
  predate the SLAAT mission. Flagged because `SLAAT-P2-GOV`'s deliverable is
  "verify clean compilation... across the estate" and this will fail that gate
  unless fixed first, by whichever card/session owns the dashboard.
- **Python cache-permission hazard (prior-errata category, reconfirmed):**
  `python3 -m compileall` on `fe-signalloom/src` fails with `PermissionError`
  on every file unless `PYTHONPYCACHEPREFIX` is redirected off the worktree
  (same family as the already-documented `GOCACHE`/`UV_CACHE_DIR` sandbox
  hazard). Fixed in this run by exporting
  `PYTHONPYCACHEPREFIX=/tmp/slaat-pycache`; Phase 2 cards building Python
  should do the same.
