# Signal Loom UI flows

This design model was reconstructed from the production dashboard route table,
sidebar, unit tests, and root Playwright acceptance suites on 2026-08-11. The
demo changes information hierarchy and presentation; it does not redefine the
production route contracts.

## Decision model

The product's fundamental unit is a governed workload decision, not a page:

```text
Discover identity → establish ownership → govern agent → assess controls
                  → investigate finding → contain/remediate → prove outcome
```

The standalone demo starts later in that loop because its fixtures already
contain governed agents. Its primary path is:

```text
Trust overview → Agent health → Trust topology → Controls & evidence
               → Activity history → Evidence-backed decision
```

## Navigation architecture

| Group | Demo label | Demo route | Production route/source |
|---|---|---|---|
| Overview | Trust overview | `/` | New demo synthesis; production `/` redirects to `/agents` |
| Estate | Agent health | `/agents` | `/agents` |
| Estate | Trust topology | `/topology` | `/agent-trust-topology` |
| Assurance | Controls & evidence | `/compliance` | `/compliance` plus nested policy/posture/risk views |
| Assurance | Activity history | `/audit` | `/audit` |
| Trust fabric | Trust foundations | `/cryptography` | `/cryptography` |
| Trust fabric | Connected services | `/federated-services` | `/federated-services` |
| Trust fabric | Risky access paths | `/collusion-access` | `/collusion-access` |
| Permissions | Permission findings | `/rbac-analysis` | `/rbac-analysis` |
| Permissions | Permission map | `/rbac-explorer` | `/rbac-explorer` |
| Permissions | Credential lifecycle | `/supercred` | `/supercred` |
| Account | Workspace settings | `/settings` | `/settings` |

Trust fabric and Permissions are hidden until **Superadmin** is enabled. This
is deliberately visibility-only: direct URLs stay registered and reachable,
matching `src/auth/superadmin.ts` in the production dashboard.

## Tested production journeys

| Journey | Test evidence | Intent preserved by demo |
|---|---|---|
| Authenticated route matrix | `test/acceptance/smoke.spec.ts`, `signalloom-test-1.spec.ts` | Stable sidebar navigation leading to route-specific H1 content |
| Login and logout | `test/acceptance/signalloom-login.spec.ts`, `auth.setup.ts` | Omitted intentionally: static demo needs no identity service |
| Agent credential issue/revoke | `test/acceptance/credential-lifecycle.spec.ts` | Credential lifecycle narrative, state, consequence, audit proof |
| Compliance nested routes | `test/acceptance/supercred-live-pages.spec.ts` | Controls expose reason, affected agents, provenance, and evidence |
| SuperCred instructor/audience | `supercred-page.spec.ts`, `supercred-two-window.spec.ts` | Credential action connects to agent, compliance, topology, and audit views |
| RBAC import and analysis | `rbac-analysis.spec.ts`, `afm-integration.spec.ts` | Formal finding links to focused permission map and human-readable proof |
| RBAC exploration | `rbac-explorer.spec.ts` | Permission map begins from an investigation question |
| Unknown route recovery | `smoke.spec.ts` | Demo shows a useful recovery page rather than silently masking mistakes |

## Five demo paths

1. **Daily trust check:** Trust overview → Agent health → select CardVault →
   Trust topology → inspect blocked path.
2. **Control failure:** Controls & evidence → filter Needs attention → inspect
   credential rotation → Activity history.
3. **Access-risk triage:** enable Superadmin → Risky access paths → Permission
   findings → Permission map.
4. **Credential incident:** enable Superadmin → Credential lifecycle → revoke →
   Trust topology → Activity history.
5. **Evidence review:** Trust overview → Controls & evidence → evidence source →
   Activity history → create evidence brief.

## Run the production Signal Loom tests

From repository root:

```bash
# Fast dashboard unit gates (no cluster)
cd d2-signalloom/apps/dashboard-signalloom
bun install --frozen-lockfile
bun run test
bun run typecheck
bun run lint

# Static D2 topology and BATS checks
cd ../../
make -C d2-signalloom test

# Full runtime prerequisites and browser acceptance
make demo-signalloom-up
make demo-signalloom-test
make acceptance-test

# Focused Playwright matrix after the stack and port-forwards are ready
cd test/acceptance
bunx playwright test --project=smoke
```

Runtime access uses port `5173` because Dex issuer and redirect URIs are pinned
to it. The login is `demo-user@signalloom.local` / `demo-user`. The repository's
`scripts/acceptance-test.sh` establishes the required Gateway and service
port-forwards for `make acceptance-test`.

### Do not trust a green run blindly

- BATS and Playwright guards can report tests as skipped; inspect output for
  `skip` before treating green as evidence.
- Most acceptance helpers default to fixture/demo data. Live SuperCred tests
  explicitly disable demo mode.
- OIDC tokens are stored in `sessionStorage`; Playwright `storageState` alone
  does not restore them. `fixtures.ts` replays `.auth-session.json` before boot.
- Sidebar badge counts alter accessible names. Production helpers navigate by
  route `href`, not fragile exact text.
- The onboarding overlay can cover a healthy sidebar. Helpers seed
  `sl_onboarding_skipped` where onboarding is outside the test's purpose.
- Current `playwright.config.ts` project patterns do not include every
  `supercred-*.spec.ts`; invoke an omitted spec explicitly when validating it.

## Beautiful UI influence

The demo uses the patterns visible at <https://www.beautifului.dev/> as design
inspiration: crafted primitives, compact live-status chips, expandable context,
filterable records, restrained motion, and polished loading feedback. It does
not copy source code or depend on the site. Signal Loom's evidence/provenance
requirements remain the stronger design constraint.
