# Walking Demo Runbook — Signal Loom Dashboard in OSRAMP

> **PARTIALLY SUPERSEDED, 2026-08-14.** Written 2026-07-28, when the API shim was not yet
> at contract and the demo could not be walked. That gap closed on 2026-07-28 (see the
> banner on `APPRAISAL.md`), so the "known gaps" below no longer describe reality and the
> walk needs no preconditions from `APPRAISAL.md`. The bring-up and reach paths are still
> broadly right and are why this file is kept rather than deleted; the corrections are
> marked inline. Anything about who is building what "tonight" refers to July 2026 and
> should be read as historical.
>
> For what the four screens now do, read
> [`../signalloom/audit-trail.md`](../signalloom/audit-trail.md) (Audit Trail),
> [`../signalloom/display-currency.md`](../signalloom/display-currency.md) (Settings →
> Currency), and [`../FAQ.md`](../FAQ.md).
>
> **Before you believe any of this walked:** `make check-deployed-staleness`. The pods may
> be older than the code you just built — see `TESTING.md` § *Is the running code the code
> you tested?*.

> Grounded against the root `Makefile`, `gateway-route.yaml`, `dex.yaml`, and the Dex-login work ISA.
> Two reach paths exist; **Path 1 (single-origin, port 5173)** is the one the parallel Dex-login process is building — prefer it. Path 2 (Envoy gateway :18443) is the fallback.

## Preconditions (Antecedents)
- `make up` completed and `make healthcheck` green (Kind + Zot + Flux + shared foundation).
- Dex pod Ready in `inf-signalloom`; `dashboard-signalloom` + `fe-signalloom` Ready in `fe-signalloom` ns.
- `CLUSTER_DOMAIN = osramp.acme.local` (self-signed `*.osramp.acme.local` cert → accept in browser / `-k`).

## Bring-up

> ⚠️ **IMAGE-OWNERSHIP GATE (read first).** `make demo-signalloom-up` rebuilds **and pushes** the `dashboard-signalloom` image (via `signalloom-images` → `build-sign-dashboard.sh`, Makefile:232→152). If the parallel Dex-login process is mid-flight on that image, running this yourself **IS** the last-write-wins collision this plan warns about. → If that process is active, DO NOT run `demo-signalloom-up`; let it own the bring-up, or explicitly agree who pushes the image tonight.

```bash
cd <governor-root>
./scripts/setup.sh                 # 0. optional toolchain
make up                            # 1. Kind + Zot + signing keys + Flux bootstrap + healthcheck
make demo-signalloom-up            # 2. push artifacts, build+sign+load dashboard, deploy Dex + API + dashboard + routes
                                   #    ⚠️ rebuilds+pushes dashboard image — see IMAGE-OWNERSHIP GATE above
make demo-signalloom-test          # 3. NOT a no-risk Flux check — runs `make -C d2-signalloom test`
                                   #    (config render + validate, Makefile:239→237); can fail on config issues
                                   #    independent of a live cluster. Skip if you only want the walk.
kubectl get pods -n fe-signalloom  # 4. dashboard-signalloom + fe-signalloom Ready
kubectl get pods -n inf-signalloom #    dex Ready
```

## Path 1 — single-origin (preferred; matches Dex-login process)
Dashboard nginx proxies `/dex` + `/api` → one origin, no CORS, no browser Dex-DNS problem.
```bash
kubectl -n fe-signalloom port-forward svc/dashboard-signalloom 5173:8080 &
# open: http://localhost:5173/   →  login  demo-user / password
```

## Path 2 — Envoy gateway (fallback, TLS)
```bash
GW=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=cluster -o jsonpath='{.items[0].metadata.name}')
kubectl -n envoy-gateway-system port-forward "svc/${GW}" 18443:443 &
echo '127.0.0.1 dashboard.osramp.acme.local' | sudo tee -a /etc/hosts
# open: https://dashboard.osramp.acme.local:18443/   (accept self-signed cert first)
```

## The walk

> The "(after contract items 1-3 in APPRAISAL.md land)" qualifier this heading used to
> carry is spent — they landed on 2026-07-28 and all 28 endpoints serve live data. The
> per-step "needs X shape" notes are likewise historical and are kept only so the shapes
> are named somewhere.

1. Land → login (`demo-user`/`password`) → dashboard shell renders.
2. **Agents** → list shows tenant-demo agents (needs `AgentListResponse` shape).
3. **Compliance** → summary + posture + frameworks (needs `/compliance/summary`, `/compliance/posture`, `/frameworks`).
4. **Audit Trail** → events table (needs `AuditListResponse` shape w/ `timestamp`).
5. **Settings** → tenant settings (needs `/tenant/settings` path + `TenantSettingsResponse`).

Two things on this walk have changed materially since it was written and will read as
faults if you are not expecting them:

* **Audit Trail rows name an email address, or `demo-actor`.** Both are correct. The
  actor comes from the validated token, and the rows still reading `demo-actor` are writers
  not yet converted. See [`../signalloom/audit-trail.md`](../signalloom/audit-trail.md).
* **Risk and exposure figures default to USD** while the demo estate reports in GBP, so
  most figures on the walk are converted and carry a rate date beside them. Settings →
  Currency changes it, per user. See
  [`../signalloom/display-currency.md`](../signalloom/display-currency.md).

The "do not click" list below is from July 2026 and has not been re-verified; treat it as a
hint about where to be careful rather than a current statement of what 404s.
Do **not** click: Agent detail/register, Onboarding/connectors, Redeem invite, NHI, api-key rotate (still 404).

## Known gaps / missing targets (flag before the demo)

> **Stale as written.** The two entries struck through below were closed on 2026-07-28.
> The remaining two have not been re-verified since July 2026.

- **No human-facing "open dashboard" Make target** — only Playwright's `acceptance-test.sh` sets up :18443 and tears it down on exit. Port-forward manually (above).
- ~~**`api_compat.py` not yet at contract** — Agents/Compliance/Audit/Settings will render blank/error until APPRAISAL.md items 1-3 land.~~ **Closed 2026-07-28.** All 28 endpoints serve live data from PostgreSQL.
- ~~**Image race** — ensure only ONE process rebuilds/pushes `dashboard-signalloom` tonight.~~ Referred to a specific July 2026 evening. The general point survives: coordinate before rebuilding a shared image, and run `make check-deployed-staleness` afterwards to prove which build is actually serving.
- **Connectors** — keep `VITE_CONNECTORS_API_MODE=mock`; live mode 404s (no `/api/connectors*` server; PR #19 unmerged).

## First-render probe (the honest "it walks" test)
Assert the **root layout renders after login** (not just `/api/agents` 200):
```bash
# via Interceptor (mandatory for web verification):
#   interceptor open http://localhost:5173/  → login → screenshot Agents+Compliance+Audit+Settings
```
Passing = each of the 4 screens shows real tenant-demo data, console clean of unhandled throws.
