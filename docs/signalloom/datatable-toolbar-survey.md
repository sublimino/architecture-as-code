# DataTable toolbar dialects — survey

Ten agents migrated nine superadmin pages to `DataTable`'s `toolbar=` slot in one day, each
told to keep its filter strip local. `toolbar=` adoption went from zero to 31 call sites. It
also produced six dialects of one idea. This is what they converged on, what they did not,
and what `DataTable` should take.

Paths below are relative to `d2-signalloom/apps/dashboard-signalloom/src/`.

## The six dialects

| # | Page | Local component | Search | Chips | Select | Count | Clear |
|---|---|---|---|---|---|---|---|
| 1 | `pages/CryptographyPage.tsx:238` | `FilterBar` | ✅ | ✅ | — | ✅ | ❌ |
| 2 | `pages/FederatedServicesPage.tsx:313` | `FilterBar` (separate copy) | ✅ | ✅ | — | ✅ | ❌ |
| 3 | `pages/CredentialInventoryPage.tsx:238-333` | `ToolbarSearch`/`Select`/`Count`/`Toolbar` | ✅ | — | ✅ | ✅ | ✅ in strip |
| 4 | `pages/RbacExplorerPage.tsx:248` | `TableToolbar` | ✅ | ✅ (n groups) | — | ✅ | ✅ in empty |
| 5 | `pages/CollusionAccessPage.tsx:485` | `FilterStrip` | ✅ | ✅ | — | ✅ | ✅ in empty |
| 6 | `pages/NetworkTestsPage.tsx:185` | `FilterToolbar` | ✅ | ✅ | — | ✅ | ✅ in strip |
| — | `pages/SuperCredPage.tsx:768-803` | inline + `FilterChip:268` | ✅ | ✅ | — | ✅ | ❌ |
| — | `pages/FleetDemoPage.tsx:799-880` | inline, no extraction | ✅ | ✅ | ✅ | ✅ | ✅ in strip |

### The convergence is real, but not where it looks

Dialects 1 and 2 are the same 58 lines: `diff` of `CryptographyPage.tsx:238-295` against
`FederatedServicesPage.tsx:313-376` is six lines, all of them comments. **That proves nothing.**
Commit `4fe7816` says so in its own subject: *"adopt Cryptography's filter strip verbatim on
Federated Services"*. It is a deliberate copy, not two agents arriving at one answer, and any
argument built on it is built on sand.

The evidence is the commit that copy **deleted**. At `06d60cf`, Federated Services had invented
its own `FilterToolbar`, with no sight of the others, and it independently landed:

- the outer `role="group"` named from the table's noun;
- a **nested** `role="group"` around the chip vocabulary — which only `RbacExplorerPage:274`
  otherwise has;
- the order search → chips → clear → count, with a written argument for it;
- a chip carrying a dimmed count and no `aria-label`;
- the sentence `{shown} of {total} shown`;
- an `active` boolean driving the clear control, `narrowed` in `NetworkTestsPage:153`;
- every test-id derived from one `testIdPrefix`.

Six of seven decisions, arrived at alone. That, not the byte-identical pair, is the mandate for
hoisting — and it is a stronger one, because it is convergence under a shared canon rather than
copying under a shared branch.

**The normalisation was not free.** `06d60cf`'s strip rendered "Clear filters" always and merely
disabled it, arguing that a control appearing only when needed moves everything beside it at the
moment the reader is aiming. Three surviving dialects render it conditionally, so conditional
wins on count — but Cryptography's strip, which replaced it, has no clear control at all.
Federated Services and Cryptography have had no way to clear a filter since, across twelve
tables. Consistency was bought with a working affordance, and nobody noticed because the diff
looked like a tidy-up.

### Won and lost, axis by axis

Winner, then who lost it and what that costs. Different dialects win different axes; none wins
outright.

| Axis | Won by | Lost by, and the cost |
|---|---|---|
| Controls offered | `FleetDemoPage.tsx:799-880` — search, chips, select, clear, count *and* a `HelpHint` (`:873`) | dialects 1-2: no clear at all |
| Decomposition | `CredentialInventoryPage.tsx:238-333` — four named parts, shared by both its tables | `FleetDemoPage`: 82 inline lines no second table can use |
| Facets | dialects 1, 2, 4, 5, 6 — chips carrying counts | dialect 3: no chips, so the shape of the data is invisible before you filter it |
| Facet grouping | `RbacExplorerPage.tsx:274` — each vocabulary its own nested named group | dialect 6: one flat group, so a second vocabulary would announce as one list |
| Label association | `CredentialInventoryPage.tsx:264-286` — a real `<label>`, `aria-label` *composed* from the visible word (`:277`) | `FleetDemoPage.tsx:843`: hand-written, nothing checks it. `CollusionAccessPage.tsx:535`: facet label is a bare `<span>`, so chips announce with no subject |
| Clear affordance | `NetworkTestsPage.tsx:153,220-230` — explicit `narrowed`, documented as never conditioned on row count | dialects 1-2: absent across twelve tables, undoable only by reload. Dialects 4-5: empty-panel only, so narrowing 200→3 has no reset until 0 |
| Empty branch | `CredentialInventoryPage.tsx:764` — three states; `state === null` suppresses the panel mid-load so a slow API is not a finding | everyone else: two states, a slow load reads as a finding |
| Predicate threading | `CryptographyPage.tsx:320-338` — a `useFilter` hook, one line per table (`:569-574`) | — |
| Test-ids | dialects 1, 2, 4, 5, 6 — all ids from one `idPrefix` | `SuperCredPage.tsx:780-801`: every id a literal, drifts silently on rename |

Dialect 3 is the best *component*, dialect 6 the best *contract*, FleetDemo the best *strip* and
the worst code — and the best whole answer was deleted in `06d60cf` before anyone compared it.

## What DataTable should absorb

**1. The labelled wrapper — and this is not a new component, it is a missing prop.**
`DataTable.tsx:268` already renders `<div style={toolbarStyle}>` where `toolbarStyle`
(`:134-140`) is `display:flex; flexWrap:wrap; alignItems:center; gap:8`. Every single caller
then nests a *second* div inside it with byte-identical style, for no reason except to attach
`role="group"` and `aria-label`. That exact style literal appears 11 times across `pages/`.
A `toolbarLabel?: string` prop deletes all 11 and the double div with them. It absorbs no
behaviour, reads none of the toolbar, and cannot grow options.

**2. An action slot on `EmptyState`, not on `DataTable`.** `EmptyState` (`components/
EmptyState.tsx:17-26`) has no action slot, so the two dialects that put "Clear filters" in the
empty panel both defeat it with a negative margin — and they do not agree on the number:
`RbacExplorerPage.tsx:330` uses `-34`, `CollusionAccessPage.tsx:573` uses `-32`, for the same
button under the same component with the same `60px 24px` padding. Two pages reaching
independently for a magic offset and landing 2px apart is the clearest missing-slot signal in
the codebase.

## What DataTable must not absorb

The predicate, the chip vocabulary, the counts, and the empty-state wording. The header
comment at `DataTable.tsx:23-48` argues this from principle; the migration supplies the proof:

- The two hand-rolled `useFilter` hooks **already diverged on their type**.
  `CryptographyPage.tsx:322` takes `chipOf: (row: T) => string`; `FederatedServicesPage.tsx:410`
  takes `(row: T) => string | readonly string[]`, because a service can sit in several zones.
  Two copies of one hook, one week, incompatible signatures. A single owned predicate would
  have forced one of those pages into a boolean escape hatch.
- Two pages needed a *bespoke extra node* in the strip, on different sides of the chips:
  `CollusionAccessPage.tsx:517` (`hint?`, a `HelpHint` after the facet label) and
  `NetworkTestsPage.tsx:157` (`tally?`, a disclosure after the count). A shared component
  absorbing the strip's contents grows exactly the option list `DataTable`'s comment warns of.
- Counts are computed against the *whole* table, not the result
  (`FederatedServicesPage.tsx:437-439` explains why: chips counting the filtered set read 0
  for every unselected option and stop being a way back). That is a page-level fact about the
  unfiltered source array, which `DataTable` never sees — it is handed the narrowed one.

So: the layout, the labelling and the control *chrome* are shared; the contents are not.

## What was built

`src/components/DataTableToolbar.tsx` — the converged strip as a real module, rendered by the
Design System's third DataTable example and **by nothing else**. It is not adopted in any of the
nine pages and `DataTable` is unmodified, which is what makes it cheap to change after review.

Six exports, each traceable to a dialect that won its axis: `DataTableToolbar` (labelled wrapper,
all six), `ToolbarSearch` (composed accessible name, dialect 3), `ToolbarFacet` (nested named
group, `06d60cf` + dialect 4), `ToolbarSelect` (`<label>` + composed name, dialect 3),
`ToolbarClear` (`active` never conditioned on row count, dialect 6), `ToolbarCount` (dialect 3's
optional noun). Children-composed rather than named slots, so the two pages needing a bespoke
node mid-strip do not force a prop each; the order convention is asserted by a test over the
specimen instead of enforced by the API.

**It never sees a row** — no `data`, no predicate, no `searchKeys`, no comparator, no count
arithmetic, no state. `DataTableToolbar.test.tsx` asserts that against the module's own source,
because the failure mode is an *addition* that would pass every behavioural test in the file.

## What the agents wanted and could not have

Every page hand-rolling the same thing *is* the request. Derived from the tree:

- **A chip.** `chipStyle(selected)` is defined four times — `CollusionAccessPage.tsx:473`,
  `RbacExplorerPage.tsx:207`, `FleetDemoPage.tsx:161`, `NetworkTestsPage.tsx:175` — plus two
  inline copies (`CryptographyPage.tsx:264-288`, `FederatedServicesPage.tsx:343-368`), plus
  `SuperCredPage.tsx:268` (`FilterChip`), plus the Design System specimen itself
  (`DesignSystemPage.tsx:1101-1122`). Eight copies of one rule, and the AA rationale comment
  ("tinted fill plus a full-strength border, never a solid accent") is pasted verbatim in five
  of them. This is the strongest candidate for the follow-up: a `FilterChip` in
  `components/` is pure presentation with no predicate attached.
- **A search input.** `minWidth: 230` with the same padding and border in nine files.
- **A count line.** "`{shown} of {total} shown`" in nine files.
- **A filtered-empty panel.** Five copies, two of them fighting `EmptyState` with negative
  margins (above).
- **A three-way empty branch.** Only `CredentialInventoryPage.tsx:764` gets loading /
  genuinely-empty / filtered-empty right; the pattern is worth a shared helper.

One page did **not** migrate: `AgentsPage.tsx:3` still carries `// TODO: migrate table to
DataTable`, and hand-rolls the strip at `:636-645` stacked *above* its table — the exact
composition `DataTable`'s `toolbar` prop exists to make impossible. It remains the page the
Design System's second DataTable example is named after.
