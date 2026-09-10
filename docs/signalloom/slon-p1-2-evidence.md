# Evidence Document — SLON-P1-2: 3-Tier Navigation Hierarchy (View, Control, Design)

**Task ID:** `SLON-P1-2`  
**Card Title:** Restructure sidebar into View, Control, Design categories  
**Date:** 2026-09-10  
**Status:** PASS  
**Branch / Worktree:** `/home/andy/src/.worktrees/0ad83/osramp-demo` (target `integration/slon-v0.1.0`)

---

## 1. Executive Summary

In accordance with the **SP-2 Invariant** for the Signal Loom First User and Agent Onboarding mission, the left-hand navigation sidebar in `dashboard-signalloom` has been restructured into a strict 3-tier hierarchy: **View**, **Control**, and **Design**.

Persistent utility anchors have been added for **Onboarding** (`/onboarding`) and **Help & Support**, while responsive rail collapsing, keyboard navigation (digit hotkeys 1–9 and `/` search focus), accessible ARIA landmarks, and precise active route highlighting have been fully implemented and verified.

---

## 2. 3-Tier Hierarchy & Route Contract

| Tier | Item Label | Route | Icon Kind | Keyboard Shortcut |
| :--- | :--- | :--- | :--- | :---: |
| **View** | Overview | `/overview` | `overview` | `1` |
| **View** | Agents | `/agents` | `agents` | `2` |
| **View** | Topology | `/topology` | `topology` | `3` |
| **View** | Activity | `/activity` | `activity` | `4` |
| **View** | FAIR Risk | `/risk` | `risk` | `5` |
| **Control** | Policies | `/policies` | `policies` | `6` |
| **Control** | Containment | `/containment` | `containment` | `7` |
| **Control** | Approvals | `/approvals` | `approvals` | `8` |
| **Control** | Audit Trail | `/audit` | `audit` | `9` |
| **Design** | Workspaces | `/workspaces` | `workspaces` | — |
| **Design** | Connectors | `/connectors` | `connectors` | — |
| **Design** | Fleet Config | `/fleet` | `fleet` | — |
| **Design** | Settings | `/settings` | `settings` | — |
| **Utilities** | Onboarding | `/onboarding` | `onboarding` | — |
| **Utilities** | Help & Support | modal trigger | `docs` | — |

*Note:* Superadmin-eligible routes (`/cryptography`, `/credential-inventory`, `/federated-services`, `/collusion-access`, `/rbac-analysis`, `/rbac-explorer`, `/network-tests`, `/supercred`, `/signal-fusion`, `/distance-latency`, `/signal-store`, `/design-system`) remain guarded behind the superadmin toggle and are cleanly organized into their corresponding domain categories with a visual separator rule.

---

## 3. Implementation Details

1. **`Sidebar.tsx`**:
   - Refactored `NAV` array into 3 sections: `View`, `Control`, `Design`.
   - Distinct SVG iconography for every single navigation destination without glyph collisions.
   - Persistent utility anchors region at the bottom of the navigation rail for `Onboarding` and `Help & Support`.
   - Dynamic sliding selection box (`.sl-sidebar__selection`) with exact DOM coordinate tracking.
   - Quick search input with `/` shortcut and `Escape` clearing.
   - Collapsible rail with `aria-expanded` and persistent state in `localStorage`.
2. **`App.tsx`**:
   - Added routes for `/overview`, `/topology`, `/activity`, `/risk`, `/policies`, `/containment`, `/approvals`, `/workspaces`, `/connectors`, `/fleet`, `/settings`, `/onboarding`.
   - Added `EXTRA_ROUTE_LABELS` and `routeLoadingLabel` resolution.
3. **`Sidebar.test.tsx`**:
   - Comprehensive test suite covering SP-2 3-tier sequence, category heading filtering, persistent anchors, keyboard navigation, collapse/expand states, and active link precision.
4. **`test/acceptance/navigation.spec.ts`**:
   - End-to-end Playwright acceptance test suite covering 3-tier navigation, route activation, persistent anchors, keyboard shortcuts, and rail collapse.
5. **`SPEC-REGISTRY.tsv` & `playwright.config.ts`**:
   - Registered `navigation.spec.ts` in the spec registry and smoke test suite match pattern.

---

## 4. Verification Evidence

### 4.1. Unit & Component Test Suite
```
 RUN  v3.2.7 /home/andy/src/.worktrees/0ad83/osramp-demo/d2-signalloom/apps/dashboard-signalloom

 Test Files  156 passed (156)
      Tests  3088 passed | 1 skipped (3089)
   Duration  22.37s
```

### 4.2. `Sidebar.test.tsx` Suite
```
 Test Files  1 passed (1)
      Tests  84 passed (84)
   Duration  7.31s
```

### 4.3. Acceptance Spec Registry Guard
```
$ bats test/acceptance-spec-coverage.bats
acceptance-spec-coverage.bats
   the guard can read every project in playwright.config.ts1/7 ✓ the guard can read every project in playwright.config.ts
   every spec on disk has exactly one registry row, and every row has a...2/7 ✓ every spec on disk has exactly one registry row, and every row has a spec
   every registry runner is a known kind, and every non-CI row gives a ...3/7 ✓ every registry runner is a known kind, and every non-CI row gives a reason
   a spec matches a playwright project if and only if the registry says so4/7 ✓ a spec matches a playwright project if and only if the registry says so
   every ci: row names a stage that really runs that spec5/7 ✓ every ci: row names a stage that really runs that spec
   every spec a CI stage runs is registered as ci:6/7 ✓ every spec a CI stage runs is registered as ci:
   every make: row names a target whose recipe runs that spec7/7 ✓ every make: row names a target whose recipe runs that spec

7 tests, 0 failures
```

### 4.4. Production Build
```
$ bun run build
$ tsc && vite build
✓ built in 5.75s
```

---

## 5. Invariant & Architecture Compliance

- **SP-2 Invariant**: Strict 3-tier structure (View, Control, Design) maintained.
- **Accessibility**: WCAG 2.5.3 (Label in Name), keyboard navigable, ARIA landmarks.
- **Zero Layout Shifts**: CSS sticky rail, fixed dimensions, single scroll container preserved.
