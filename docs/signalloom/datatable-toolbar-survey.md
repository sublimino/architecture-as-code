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

Dialects 1 and 2 are the same 58 lines: `diff` of `CryptographyPage.tsx:238-295` against
`FederatedServicesPage.tsx:313-376` is six lines, all of them comments.

### Best on each axis

- **Controls offered — `FleetDemoPage.tsx:799-880`.** The only strip carrying search, chips,
  a select, a conditional clear, a count *and* a `HelpHint` (`:873`) explaining that filtering
  is client-side and touches nothing. Nothing else is this complete; nothing else is this
  un-reusable either, at 82 lines of inline JSX.
- **Decomposition — `CredentialInventoryPage.tsx:238-333`.** Four named parts, and the
  judgement holds: it is the only dialect where the two tables on the page share the strip
  without either one being a copy.
- **Label association — `CredentialInventoryPage.tsx:264-286`.** The only select wrapped in a
  real `<label>`, with its `aria-label` *composed* from the visible word
  (`` `Filter ${subject} by ${label.toLowerCase()}` ``, `:277`) so WCAG 2.5.3 cannot drift.
  Contrast `FleetDemoPage.tsx:843`, where the same invariant is satisfied by a hand-written
  string that nothing checks.
- **Grouping — `RbacExplorerPage.tsx:274`.** The only dialect that gives each chip *group* its
  own nested `role="group"` and `aria-label`. Everything else puts one `role="group"` around
  the whole strip, so a page with two chip vocabularies announces them as one list.
- **Empty branch — `CredentialInventoryPage.tsx:764`.** Three states, not two:
  `state === null ? undefined` suppresses the panel entirely while the load is outstanding, so
  a slow API cannot render as a finding. Every other dialect distinguishes only
  genuinely-empty from filtered-empty.
- **Clear affordance — `NetworkTestsPage.tsx:153-155, 220-230`.** An explicit `narrowed:
  boolean` prop with a comment stating it is never conditioned on the row count, which is the
  rule `DataTable.tsx:240-256` had to learn the hard way. `CredentialInventoryPage`'s
  `onClear: (() => void) | null` (`:300`) encodes the same thing more tersely.
- **Predicate threading — `CryptographyPage.tsx:320-338`.** A `useFilter` hook returning
  `{search, setSearch, chip, setChip, filtered}`, so each table is one line (`:569-574`).
  Cleanest call sites on any page.
- **Test-ids — dialects 1, 2, 4, 5, 6.** All ids derive from one `idPrefix`. `SuperCredPage`
  writes every id as a literal (`:780-801`), which is the version that goes stale.

No dialect wins outright. Dialect 3 is the best *component*; dialect 6 is the best *contract*;
dialect 8 (FleetDemo) is the best *strip* and the worst code.

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

So: the layout and the label are shared; the contents are not.

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
