# Feature flag account types

Status: implemented on `feat/account-types-w16`, 2026-10-17. EAP Full contents are a **draft** pending the principal's confirmation.

A tenant's **account type** is a named, exact set of the 23 registered feature flags. Choosing one for a tenant sets every flag and records the type. The Feature Flags page can then say which type a tenant is on, or that it has been customised away from one.

The three types:

| Id | Name | Status | Deprecated alias | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `eap_view` | EAP View (read-only) | confirmed | none | Early access, read-only. The configuration tenant-demo was running on 2026-10-17, captured live. |
| `eap_full` | EAP Full | **draft** | `eap_pilot` | Early access, full system. Today it is the former `eap_pilot` set. The principal said EAP Full "may or may not have all the feature flags": its exact contents are not yet decided. |
| `full` | Full | confirmed | `full_demo` | Every page, demo and lab. |

Superadmin mode will gain more toggles later. They are out of scope here and will be added as flags, which the matrix below and the tests then cover automatically.

## Flag matrix

The source of truth is [`contracts/feature-account-types.json`](../../d2-signalloom/contracts/feature-account-types.json). The server presets, the dashboard constants and the Playwright helper are each tested against that file. This table can only drift from the code if the file does.

| Flag | What it gates | EAP View | EAP Full (draft) | Full |
| :--- | :--- | :---: | :---: | :---: |
| `core_governance` | Core governance APIs | on | on | on |
| `audit` | Audit APIs | on | on | on |
| `compliance` | Compliance APIs | on | on | on |
| `demos_fleet` | Fleet demo | off | off | on |
| `supercred` | SuperCredential demo | off | off | on |
| `rbac_analysis` | RBAC Analysis, RBAC Explorer | off | off | on |
| `collusion_access` | Collusion & Access | off | off | on |
| `page_discovery` | Discovery | on | on | on |
| `page_agents` | Agents | on | on | on |
| `page_topology` | Topology | off | off | on |
| `page_weave` | The Weave | off | on | on |
| `page_signals` | Signals | off | on | on |
| `page_risk` | FAIR Risk | off | on | on |
| `page_policies` | Policies | on | on | on |
| `page_compliance` | Compliance | off | on | on |
| `page_audit` | Audit Trail | off | on | on |
| `page_federated_services` | Federated Services | off | off | on |
| `page_cryptography` | Cryptography | off | on | on |
| `page_credential_inventory` | Credential Inventory | off | on | on |
| `page_signal_store` | Signal Store | off | off | on |
| `page_feeds` | Feeds & Collectors | off | off | on |
| `page_network_tests` | Network Tests | off | off | on |
| `page_agentmaxxing` | AgentMaxxing demo | off | off | on |

In the sidebar, a tenant on EAP View sees Discovery, Agents and Policies, plus the ungated Users & Permissions and Settings.

### Why EAP View is the read-only type

EAP View exposes what an early-access customer needs to look at their estate: what was discovered, the governed agent registry and the policy catalogue. It hides every page that acts on agents or shows raw telemetry and evidence (Signals, the Weave, Risk, Audit, Compliance posture, credentials, keys). It also hides all demos and labs. The `audit`, `compliance` and `core_governance` API flags stay on because the pages EAP View does show depend on them. The page-level flags are what limit the view.

## Assigning a type

- **Superadmin only.** `PUT /api/v1/admin/features` and `PUT /api/v1/admin/features/{flag_key}` require `require_superadmin`. Tenant admins can open the page and read the current type, but the Apply control is disabled with an explanation.
- **Confirmed first.** On the Feature Flags page, choosing a type and pressing Apply opens a confirmation. It names the tenant and lists the pages the type enables, because applying a type changes what that tenant's users can see.
- **Audited.** Every mutation writes the existing `feature_flags.updated` audit event. Its detail now carries `applied_preset` (canonical id), `account_type` and `account_type_customised`. No new event type was needed.

## Custom

A superadmin can still toggle single flags after applying a type. After **every** flag mutation the server compares the tenant's effective flags with the recorded type's set:

- If they differ, the tenant is recorded as `customised` and the page shows **Custom, based on EAP View (read-only)**. No type card is checked.
- If a later toggle restores the exact set, `customised` clears again.

The page therefore never claims a type the flags no longer match.

A tenant that never had a type applied shows **Unassigned**. If its flags happen to equal a preset exactly, it shows **Unassigned (flags match EAP View (read-only))**. This is how tenant-demo will appear until a type is applied to it.

## API contract

`GET /api/v1/admin/features/presets` lists canonical presets only. Aliases appear on their entry, not as separate entries.

```json
{"presets": [
  {"id": "eap_view", "name": "EAP View (read-only)", "kind": "account_type", "status": "confirmed", "aliases": [], "description": "...", "flags": {"...": true}},
  {"id": "eap_full", "name": "EAP Full", "kind": "account_type", "status": "draft", "aliases": ["eap_pilot"], "...": "..."},
  {"id": "full", "name": "Full", "kind": "account_type", "status": "confirmed", "aliases": ["full_demo"], "...": "..."},
  {"id": "minimal_governance", "name": "Minimal Governance", "kind": "bundle", "...": "..."}
]}
```

`PUT /api/v1/admin/features` takes `{"tenant_id": "...", "preset": "eap_view"}`. `eap_pilot` and `full_demo` are still accepted and are recorded under their canonical ids. Adding `flags` to the same request is allowed. If those flags deviate from the preset, the tenant is recorded as customised.

`GET`/`PUT /api/v1/admin/features` responses add `account_type`:

```json
{"tenant_id": "tenant-demo", "flags": {}, "details": {},
 "account_type": {"id": "eap_view", "customised": false, "matches": "eap_view", "label": "EAP View (read-only)"}}
```

The tenant-facing `GET /api/v1/features` is unchanged.

## Storage

Migration [`074_tenant_account_types.sql`](../../d2-signalloom/apps/fe-signalloom/src/db/migrations/074_tenant_account_types.sql) adds `public.tenant_account_types (tenant_id PK, account_type, customised, updated_by, updated_at)`. The flags themselves stay in `tenant_feature_flags` (057). Both bootstrap copies are regenerated.

## How we test flag configurations

Each flag configuration is an input to the product, so each one gets tests. These are the four layers, cheapest first. The first three are implemented.

### (a) A contract test per preset

Each account type's exact flag set is pinned.

- Server: [`test_feature_account_types.py`](../../d2-signalloom/apps/fe-signalloom/src/tests/test_feature_account_types.py) writes EAP View out literally. It also checks every preset against the contract file and covers recording, customisation, aliases, superadmin-only and audit.
- Dashboard: [`accountTypes.test.ts`](../../d2-signalloom/apps/dashboard-signalloom/src/types/accountTypes.test.ts) does the same for the TypeScript constants. It also checks that the contract's tenant nav list is exactly the sidebar's flag-gated tenant items.

Changing one flag in EAP View turns both red.

### (b) A pairwise matrix for component tests

23 flags have 2^23 combinations. Most flag defects involve one or two flags, so the useful target is every value pair of every two flags.

[`flag-matrix.ts`](../../d2-signalloom/apps/dashboard-signalloom/scripts/flag-matrix.ts) builds a strength-2 binary covering array and needs 8 rows for the current registry. Row 0 has every flag off. Each flag is then given a distinct column whose other 7 entries contain exactly four ones. Two different columns of equal weight each have a one where the other has a zero. Two 4-subsets of 7 rows always share a row. Between them, those facts cover all four value combinations for every pair of flags. The output is deterministic: run `bun d2-signalloom/apps/dashboard-signalloom/scripts/flag-matrix.ts` (add `--json` for JSON output).

[`accountTypeMatrix.test.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/components/accountTypeMatrix.test.tsx) runs over the 3 account types and the 8 pairwise rows. For each configuration it checks two things:

- The sidebar shows exactly the tenant pages that configuration enables.
- Every gated tenant route renders when its flag is on and returns 404 when it is off.

The same test also checks that `App.tsx` wraps each of those routes in `GatedRoute` with the flag the contract names. That ties the rendered behaviour to the application's real routing.

### (c) Playwright per account type, by interception

`accountTypes.serve(page, flags)` in [`test/acceptance/helpers.ts`](../../test/acceptance/helpers.ts) answers `GET /api/v1/features` with a type's flag set for that page only. `accountTypes.expectSidebar` then asserts the sidebar. There is one spec per type, each registered in the smoke project:

- [`account-type-eap-view.spec.ts`](../../test/acceptance/account-type-eap-view.spec.ts)
- [`account-type-eap-full.spec.ts`](../../test/acceptance/account-type-eap-full.spec.ts)
- [`account-type-full.spec.ts`](../../test/acceptance/account-type-full.spec.ts)

**Never** set a type on a shared tenant from a test. That would change what every other spec and every person on that tenant sees. The change would also remain if the spec died before it could restore the flags.

### (d) Live smoke per type, on throwaway tenants only (not yet built)

Some checks need the server's own gating, for example `require_feature` returning 404 from the API. For these, each worker creates its own tenant, applies the type through `PUT /api/v1/admin/features` and asserts. It then deletes the tenant in a teardown that runs even when the test fails. This needs a tenant create/delete path for tests and is left as follow-up work.

## Open questions for the principal

1. **EAP Full contents.** The draft is the former `eap_pilot` set. Should EAP Full also turn on Topology, Federated Services, or any lab?
2. **tenant-demo.** It runs the EAP View flags but has no recorded type. Should EAP View be applied to it, so the page reads "EAP View (read-only)" rather than "Unassigned (flags match ...)"?
3. **Minimal Governance.** It stays as a non-account-type bundle. Keep it, or retire it?
