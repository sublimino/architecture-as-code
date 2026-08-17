/**
 * DataTableToolbar — the filter strip that goes in DataTable's `toolbar` slot.
 *
 * WHERE THIS CAME FROM. Nine superadmin pages migrated onto DataTable's
 * `toolbar` prop in a single day, each told to keep its strip local because ten
 * agents editing one shared component concurrently is unmergeable. That was the
 * right call and it worked — adoption went from zero call sites to thirty-one —
 * and it produced six dialects of one idea. This module is what the survey at
 * docs/signalloom/datatable-toolbar-survey.md found they agree on. It is a
 * report on nine pages, not a new opinion about them.
 *
 * WHY THE CONVERGENCE IS REAL, WHICH IS NOT OBVIOUS. The tempting evidence is
 * that CryptographyPage and FederatedServicesPage carry byte-identical strips.
 * That evidence is worthless: commit 4fe7816 says in its own subject line that
 * it adopted Cryptography's strip "verbatim", so the pair is a copy, not two
 * agents arriving at one answer. The real evidence is the commit that copy
 * DELETED. At 06d60cf, Federated Services had invented, with no sight of the
 * others: the outer labelled group; a NESTED labelled group around the chip
 * vocabulary; the order search → chips → clear → count, with a written argument
 * for it; a chip carrying a dimmed count and no aria-label; the sentence
 * "{shown} of {total} shown"; and an `active` boolean driving the clear
 * control. Six of the seven decisions below, independently, in a file nobody
 * else had read. That is the mandate for this module.
 *
 * WHAT IT DOES NOT DO, WHICH IS THE POINT.
 *
 * It never sees a row. There is no `data` prop, no predicate, no `searchKeys`,
 * no comparator, no count arithmetic — every value and every callback is handed
 * down, and the page still owns the state and still hands DataTable an
 * already-narrowed array. This is the same division DataTable's own header
 * comment argues for, and the migration supplied the proof: the two hand-rolled
 * `useFilter` hooks had already diverged on their TYPE within a week
 * (CryptographyPage takes `chipOf: (row) => string`, FederatedServicesPage
 * takes `string | readonly string[]`, because a service can sit in several
 * zones). A component that owned "search" would hand every caller one opinion
 * about a word they each define differently, and the escape hatch for the ones
 * it did not fit would be a prop that turns it off — two behaviours in one
 * component, which is where a fork lands anyway, only later and with more code.
 * DataTableToolbar.test.tsx asserts the absence against this file's source,
 * because the failure mode is an addition that would pass every behavioural
 * test in it.
 *
 * It holds no state, computes no counts, and derives no chip vocabulary from
 * the data. That last one is deliberate and 4fe7816 explains it: a vocabulary
 * derived from the rows can only ever offer options that match something, which
 * silently removes the one control that reaches the empty state.
 *
 * It is not wired into DataTable, and it renders no table and no empty state.
 * The survey argues DataTable should absorb the labelled wrapper — its own
 * `toolbarStyle` is already this exact flex row, and every caller nests a
 * second identical div inside it purely to hang `role="group"` on — and that
 * EmptyState should grow an action slot, since the two pages that put "Clear
 * filters" in the empty panel both fight it with a magic negative margin and
 * land 2px apart. Both are follow-ups. Nothing here presumes either.
 *
 * ONE DIALECT DISAGREED, AND IT WAS RIGHT ABOUT SOMETHING. Federated Services'
 * deleted strip rendered "Clear filters" ALWAYS and merely disabled it, arguing
 * that a control which appears only once it is needed moves everything beside it
 * at the moment the reader is aiming at something. Three surviving dialects
 * render it conditionally, and that is what `ToolbarClear` does — but the
 * objection is answered by the ORDER rather than ignored. Clear sits after the
 * chips, so the only thing its arrival can move is the count, and a count is
 * not a pointer target. Worth recording that the verbatim adoption which
 * settled this took the argument's author out with it: Federated Services and
 * Cryptography have had no way to clear a filter since, across twelve tables.
 *
 * THE ORDER IS THE CONVENTION: search, facets, select, clear, count. Search
 * first because it is what a reader reaches for unprompted; facets next because
 * they are a map of the data as much as a control; clear after the things it
 * undoes; the count last because it is the OUTCOME of everything to its left.
 * That argument is Federated Services', quoted from 06d60cf. It is not enforced
 * by the API — `DataTableToolbar` takes children, so a caller with a genuine
 * exception (Collusion & Access needs a HelpHint mid-strip, NetworkTests needs
 * a disclosure after the count) can have one without this module growing a prop
 * for it. It is enforced by a test over the specimen instead.
 */
import type { CSSProperties, ReactNode } from 'react'
import { tint } from './StatusBadge'

// ── Shared control styling ──────────────────────────────────────────────────

const STRIP: CSSProperties = {
  display: 'flex',
  flexWrap: 'wrap',
  alignItems: 'center',
  gap: 8,
}

const CONTROL: CSSProperties = {
  fontSize: 12,
  padding: '5px 9px',
  color: 'var(--text)',
  background: 'var(--surface2)',
  border: '1px solid var(--border)',
  borderRadius: 4,
  fontFamily: 'inherit',
}

const CAPTION: CSSProperties = { fontSize: 11.5, color: 'var(--muted)' }

/**
 * The selected treatment: a tinted fill plus a full-strength border, never a
 * solid accent fill — text on solid cyan or amber fails AA in at least one of
 * Dark, Light and Andy.
 *
 * `tint()` rather than a hand-written `color-mix()` string, and border
 * LONGHANDS rather than the shorthand. Both come from 4fe7816: a `border`
 * shorthand carrying a `color-mix()` is unreadable to jsdom, which puts the
 * entire selected/unselected distinction beyond the reach of a test.
 */
export function toolbarChipStyle(selected: boolean): CSSProperties {
  return {
    fontSize: 11.5,
    padding: '4px 9px',
    borderRadius: 4,
    cursor: 'pointer',
    textTransform: 'capitalize',
    fontWeight: selected ? 600 : 400,
    color: selected ? 'var(--cyan)' : 'var(--muted)',
    background: selected ? tint('var(--cyan)', 0.12) : 'var(--surface2)',
    borderWidth: 1,
    borderStyle: 'solid',
    borderColor: selected ? tint('var(--cyan)', 0.45) : 'var(--border)',
  }
}

// ── The strip ───────────────────────────────────────────────────────────────

/**
 * The labelled group every dialect wrapped its strip in, and the piece the
 * survey argues DataTable should absorb outright.
 *
 * A slot, not a schema. It reads none of its children — which is what lets the
 * two pages with a bespoke extra node keep it without this module growing a
 * prop each time.
 */
export function DataTableToolbar({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div role="group" aria-label={label} style={STRIP}>
      {children}
    </div>
  )
}

/**
 * The search box.
 *
 * `label` is required and there is no default, because this control has no
 * visible text: an unnamed search box is announced as "search" and a page with
 * six tables then has six controls with one name. Every dialect composed it
 * from the table's noun — "Search the fleet roster", not "Search".
 */
export function ToolbarSearch({
  label, placeholder, value, onChange, testId,
}: {
  label: string
  placeholder: string
  value: string
  onChange: (next: string) => void
  testId: string
}) {
  return (
    <input
      type="search"
      aria-label={label}
      placeholder={placeholder}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      data-testid={testId}
      style={{ ...CONTROL, minWidth: 230 }}
    />
  )
}

export interface ToolbarOption {
  value: string
  /** Visible text. Defaults to `value`, which is what most vocabularies want. */
  label?: string
  /**
   * Rows matching this option in the WHOLE table, not in the current result.
   * Optional, because a vocabulary with nothing useful to count should show
   * nothing rather than a zero it has not measured.
   */
  count?: number
}

/**
 * One chip vocabulary, as a group with its own name inside the strip.
 *
 * The nesting is the part worth having and only two dialects had it. A strip
 * carrying two vocabularies under one flat `role="group"` announces them to a
 * screen reader as a single undifferentiated list of nine buttons.
 */
export function ToolbarFacet({
  label, value, options, onChange, testIdPrefix,
}: {
  /** Names this vocabulary specifically: "Filter the services by source". */
  label: string
  value: string
  options: readonly ToolbarOption[]
  onChange: (next: string) => void
  testIdPrefix: string
}) {
  return (
    <div role="group" aria-label={label} style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
      {options.map((option) => {
        const selected = option.value === value
        return (
          <button
            key={option.value}
            type="button"
            onClick={() => onChange(option.value)}
            aria-pressed={selected}
            data-testid={`${testIdPrefix}-${option.value}`}
            style={toolbarChipStyle(selected)}
          >
            {/* No aria-label anywhere on a chip. The visible text IS the
                accessible name, so the two cannot disagree and a speech-input
                user reaches the control they can see. The surrounding group
                supplies the "by source" the chip itself omits. */}
            {option.label ?? option.value}
            {option.count !== undefined && <span style={{ color: 'var(--dim)' }}> {option.count}</span>}
          </button>
        )
      })}
    </div>
  )
}

/**
 * A facet as a select rather than chips.
 *
 * Reach for this past about five options, or for a second vocabulary beside a
 * chip row: two chip rows read as one row of nine controls with no grouping,
 * and global.css already themes every select in the product.
 *
 * The accessible name is COMPOSED from the visible label rather than written
 * out. An explicit `aria-label` replaces the wrapping `<label>`'s text as the
 * name, so "Filter services by owner" has to contain the visible "Owner" or a
 * speech-input user saying "Owner" reaches nothing — WCAG 2.5.3, and composing
 * it is what stops the two drifting apart later.
 */
export function ToolbarSelect({
  label, subject, value, options, onChange, testId,
}: {
  /** The visible word beside the control: "Owner". */
  label: string
  /** What is being filtered, for the composed name: "the services". */
  subject: string
  value: string
  options: readonly ToolbarOption[]
  onChange: (next: string) => void
  testId: string
}) {
  return (
    <label style={{ ...CAPTION, display: 'flex', alignItems: 'center', gap: 6 }}>
      {label}
      <select
        aria-label={`Filter ${subject} by ${label.toLowerCase()}`}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        data-testid={testId}
        style={{ fontSize: 12 }}
      >
        {options.map((option) => {
          const text = option.label ?? option.value
          return (
            <option key={option.value} value={option.value}>
              {/* No count means no parenthesis. An absent measurement and a
                  measured zero are different facts. */}
              {option.count === undefined ? text : `${text} (${option.count})`}
            </option>
          )
        })}
      </select>
    </label>
  )
}

/**
 * The way out, rendered only while there is something to undo.
 *
 * `active` is a fact about the OTHER controls and never about this one, and
 * never about the row count either. Both of those would be the defect
 * DataTable's footer comment documents — a control whose own value decides
 * whether it renders, leaving a state the user cannot leave. An empty result is
 * precisely when this is needed, and DataTable keeps the toolbar above the
 * empty panel by construction, so it is still here to click.
 */
export function ToolbarClear({
  active, onClear, testId,
}: {
  active: boolean
  onClear: () => void
  testId: string
}) {
  if (!active) return null
  return (
    <button
      type="button"
      className="btn btn-secondary"
      onClick={onClear}
      data-testid={testId}
      style={{ fontSize: 11, padding: '4px 10px' }}
    >
      {/* No aria-label: the visible text is the accessible name. */}
      Clear filters
    </button>
  )
}

/**
 * The outcome of every control to its left, which is why it goes last.
 *
 * `total` is the size of the whole table, not of the current result — the two
 * being different is the entire information content of the sentence.
 */
export function ToolbarCount({
  shown, total, noun, testId,
}: {
  shown: number
  total: number
  /** "identities", "services". Omit it where the table's name already says it. */
  noun?: string
  testId: string
}) {
  return (
    <span data-testid={testId} style={CAPTION}>
      {shown} of {total} {noun ? `${noun} ` : ''}shown
    </span>
  )
}
