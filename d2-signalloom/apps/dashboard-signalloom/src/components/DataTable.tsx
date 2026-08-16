/**
 * DataTable — reusable table with client-side pagination and column sorting.
 *
 * Uses var(--token) CSS custom properties for consistent theming. Zero external
 * dependencies — just React + inline styles.
 *
 * Usage:
 *   <DataTable
 *     columns={[
 *       { key: 'name', label: 'Name', sortable: true },
 *       { key: 'status', label: 'Status' },
 *     ]}
 *     data={items}
 *     pageSize={10}
 *     renderRow={(item, i) => (
 *       <tr key={i} style={{ borderBottom: '1px solid var(--border)' }}>
 *         <td style={DataTable.td}>{item.name}</td>
 *         <td style={DataTable.td}>{item.status}</td>
 *       </tr>
 *     )}
 *   />
 *
 * ONE COMPONENT, NOT TWO. The question that produced this note was whether the
 * advanced call sites want a second component — `DataTableFiltered` beside
 * `DataTable`. They do not, and the reason is specific rather than a general
 * preference for fewer files.
 *
 * What actually differs between a simple table and a filtered one is the
 * PREDICATE, and the predicate is the one part that can never be shared:
 * AgentsPage searches name, owner and type, CredentialInventoryPage filters on
 * a computed status that depends on the clock. A component that owned "search"
 * would be handing every caller one opinion about a thing they each define
 * differently, and the escape hatch for the callers it did not fit would be a
 * prop that turns it off — at which point there are two behaviours in one
 * component and we have arrived where a fork would have, only later. So the
 * page keeps the predicate and hands down an already-narrowed array.
 *
 * What does NOT differ, and is therefore what these props share, is the
 * CHROME and one bug. The chrome is the strip above the table and the
 * nothing-matched panel. The bug is that composing them by hand strands the
 * user: write `rows.length === 0 ? <EmptyState/> : <DataTable/>` and the
 * filter control that caused the empty result disappears along with the table,
 * leaving no way to undo it except a reload. Every caller has to remember to
 * hoist the toolbar out of that ternary. Passing both in means they cannot get
 * it wrong, because the toolbar renders on the empty branch by construction.
 *
 * Both props are optional and neither changes an existing call site. A table
 * that is just a list stays the four-line call at the top of this comment.
 *
 * // TODO: server-side pagination when API supports it
 */
import { useState, useMemo, useCallback, useRef, useEffect, type ReactNode, type CSSProperties } from 'react'
import HelpHint from './HelpHint'

// ── Types ───────────────────────────────────────────────────────────────────

export interface Column<T> {
  /** Key used to access the data field for sorting. */
  key: keyof T & string
  /** Display label in the header. */
  label: string
  /** Whether clicking the header sorts by this column. Default false. */
  sortable?: boolean
  /**
   * Plain-English explanation of what this column means, shown behind a "?".
   *
   * Only worth setting where the label does not already say it: a "?" that
   * restates the header is noise. Omit it and no hint renders.
   */
  help?: string
}

type SortDir = 'asc' | 'desc' | null

interface SortState {
  key: string
  dir: SortDir
}

/** The offered page sizes. The current size is added if it is not one of these. */
const PAGE_SIZE_OPTIONS = [10, 25, 50] as const

export interface DataTableProps<T> {
  columns: Column<T>[]
  data: T[]
  /** Number of rows per page. Default 10. */
  pageSize?: number
  /** Custom row renderer. Receives the item and its index within the full sorted array. */
  renderRow: (item: T, index: number) => ReactNode
  /**
   * Hide the PAGE NAVIGATION — prev/next and "Page 1 of 1" — when everything
   * fits on one page. Default true.
   *
   * Scoped to the navigation, not the footer. The rows-per-page select and the
   * row count stay either way: see the note above `showFooter` for why the
   * select in particular can never be conditioned on how much data there is.
   */
  hidePaginationWhenSinglePage?: boolean
  /** Optional test-id prefix for pagination controls. */
  testIdPrefix?: string
  /**
   * Controls that belong above the table — a search box, filter chips, a count.
   *
   * A slot, not a feature: this renders whatever it is given and reads none of
   * it. The caller still owns the state and the predicate and still hands down
   * an already-filtered `data`. What it buys is that the strip is positioned
   * and spaced the same on every table, and that it survives the empty branch.
   */
  toolbar?: ReactNode
  /**
   * What to show instead of the table when `data` is empty.
   *
   * Rendered in place of the table, with the toolbar still above it, so a
   * filter that matches nothing can always be undone. Omit it and an empty
   * `data` renders an empty table, which is the existing behaviour.
   */
  emptyState?: ReactNode
}

// ── Shared styles (exported for use by renderRow callbacks) ─────────────────

const thStyle: CSSProperties = {
  padding: '9px 14px',
  textAlign: 'left',
  color: 'var(--muted)',
  fontWeight: 600,
  fontSize: 11,
  textTransform: 'uppercase',
  letterSpacing: '0.05em',
  whiteSpace: 'nowrap',
  userSelect: 'none',
}

const toolbarStyle: CSSProperties = {
  display: 'flex',
  flexWrap: 'wrap',
  alignItems: 'center',
  gap: 8,
  marginBottom: 12,
}

const tdStyle: CSSProperties = {
  padding: '9px 14px',
  fontSize: 13,
  color: 'var(--text)',
  whiteSpace: 'nowrap',
}

// ── Sort arrow indicator ────────────────────────────────────────────────────

function SortArrow({ dir }: { dir: SortDir }) {
  if (dir === null) {
    return (
      <span style={{ color: 'var(--border)', marginLeft: 4, fontSize: 10 }} aria-hidden>
        ⇅
      </span>
    )
  }
  return (
    <span style={{ color: 'var(--cyan)', marginLeft: 4, fontSize: 10 }} aria-hidden>
      {dir === 'asc' ? '▲' : '▼'}
    </span>
  )
}

// ── Component ───────────────────────────────────────────────────────────────

export default function DataTable<T>({
  columns,
  data,
  pageSize: initialPageSize = 10,
  renderRow,
  hidePaginationWhenSinglePage = true,
  testIdPrefix = 'datatable',
  toolbar,
  emptyState,
}: DataTableProps<T>) {
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(initialPageSize)
  const [sort, setSort] = useState<SortState>({ key: '', dir: null })

  // Reset to page 1 when data length changes (e.g. filter applied upstream)
  const dataLen = data.length
  const prevDataLen = usePrevious(dataLen)
  if (prevDataLen !== undefined && prevDataLen !== dataLen && page !== 1) {
    setPage(1)
  }

  // ── Sorting ─────────────────────────────────────────────────────────────

  const handleSort = useCallback((key: string) => {
    setSort((prev) => {
      if (prev.key !== key) return { key, dir: 'asc' }
      if (prev.dir === 'asc') return { key, dir: 'desc' }
      // Third click clears the sort
      return { key: '', dir: null }
    })
    setPage(1)
  }, [])

  const sorted = useMemo(() => {
    if (!sort.key || sort.dir === null) return data

    const key = sort.key as keyof T
    const dir = sort.dir === 'asc' ? 1 : -1

    return [...data].sort((a, b) => {
      const aVal = a[key]
      const bVal = b[key]

      // Handle nullish and NaN — push missing values to the end regardless of
      // sort direction so they never interleave with real data.
      const aNull = aVal == null || (typeof aVal === 'number' && Number.isNaN(aVal))
      const bNull = bVal == null || (typeof bVal === 'number' && Number.isNaN(bVal))
      if (aNull && bNull) return 0
      if (aNull) return 1   // a goes last, always
      if (bNull) return -1  // b goes last, always

      // Numeric comparison
      if (typeof aVal === 'number' && typeof bVal === 'number') {
        return (aVal - bVal) * dir
      }

      // String comparison (case-insensitive)
      return String(aVal).localeCompare(String(bVal), undefined, { sensitivity: 'base' }) * dir
    })
  }, [data, sort])

  // ── Pagination ──────────────────────────────────────────────────────────

  const totalPages = Math.max(1, Math.ceil(sorted.length / pageSize))
  const safePage = Math.min(page, totalPages)
  const start = (safePage - 1) * pageSize
  const pageData = sorted.slice(start, start + pageSize)

  // `emptyState` is opt-in, so an existing caller that passes none keeps
  // rendering the headers over no rows exactly as it does today.
  const showEmptyState = emptyState != null && sorted.length === 0

  // TWO QUESTIONS, NOT ONE. "Is there any data at all?" decides the footer —
  // the row count and the rows-per-page select. "Is there more than one page?"
  // decides the page navigation inside it.
  //
  // They were a single boolean, `sorted.length > pageSize`, and that predicate
  // reads the select's OWN value. Choosing a size at or above the row count
  // made it false and unmounted the footer, taking the select down with it:
  // the control disappeared as a direct consequence of being used, and nothing
  // short of a reload brought it back. A hidden control is a nuisance; a
  // control that hides itself is a state the user cannot leave, which is why
  // this is worth two booleans and a comment. The rule is now absolute — a
  // control's own value never decides whether that control renders.
  //
  // Nothing over an empty state, even when the caller asked for a pager
  // unconditionally: "Page 1 of 1 · No rows" beneath a panel that already says
  // nothing matched is furniture restating a fact. Same for zero rows without
  // an empty state — a size control over nothing controls nothing.
  const showFooter = !showEmptyState && sorted.length > 0
  const showPageNav = showFooter && (!hidePaginationWhenSinglePage || totalPages > 1)

  return (
    <div>
      {toolbar != null && (
        // Outside the empty branch below, deliberately. The whole reason this
        // is a prop rather than something the page stacks above the table is
        // that a hand-rolled `rows.length ? table : empty` ternary takes the
        // filter control down with the table and leaves the user with no way
        // to clear the filter that emptied it.
        <div data-testid={`${testIdPrefix}-toolbar`} style={toolbarStyle}>
          {toolbar}
        </div>
      )}

      {showEmptyState ? (
        <div data-testid={`${testIdPrefix}-empty`}>{emptyState}</div>
      ) : (
        <div className="card" style={{ padding: 0, overflow: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse' }}>
            <thead>
              <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                {columns.map((col, colIdx) => (
                  <th
                    key={`${col.key}-${colIdx}`}
                    style={{
                      ...thStyle,
                      cursor: col.sortable ? 'pointer' : 'default',
                    }}
                    onClick={col.sortable ? () => handleSort(col.key) : undefined}
                    aria-sort={
                      sort.key === col.key && sort.dir
                        ? sort.dir === 'asc' ? 'ascending' : 'descending'
                        : undefined
                    }
                  >
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                      <span>
                        {col.label}
                        {col.sortable && <SortArrow dir={sort.key === col.key ? sort.dir : null} />}
                      </span>
                      {col.help && (
                        // The sort handler lives on the `th`, so a click that
                        // lands on the "?" would otherwise re-sort the table —
                        // a surprise mutation from a control that only explains.
                        <span onClick={(e) => e.stopPropagation()}>
                          <HelpHint
                            label={`What ${col.label} means`}
                            testId={`${testIdPrefix}-help-${col.key}`}
                          >
                            {col.help}
                          </HelpHint>
                        </span>
                      )}
                    </span>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {pageData.map((item, i) => renderRow(item, start + i))}
            </tbody>
          </table>
        </div>
      )}

      {showFooter && (
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            marginTop: 8,
            fontSize: 12,
            color: 'var(--muted)',
            flexWrap: 'wrap',
            gap: 8,
          }}
          data-testid={`${testIdPrefix}-footer`}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span>
              {`${start + 1}–${Math.min(start + pageSize, sorted.length)} of ${sorted.length}`}
            </span>
            <select
              value={pageSize}
              onChange={(e) => {
                setPageSize(Number(e.target.value))
                setPage(1)
              }}
              style={{ fontSize: 12, padding: '2px 6px' }}
              data-testid={`${testIdPrefix}-page-size`}
            >
              {/* The current size is always an option, even when it is not one
                  of the presets. A caller can pass any pageSize — the Design
                  System's "Realistic" specimen passes 5 — and a <select> whose
                  value matches no option renders the FIRST one instead. The
                  control then reads "10 per page" while the table pages by 5:
                  it misreports its own state, which is the same defect class as
                  the footer that used to hide the control that opened it. */}
              {Array.from(new Set([...PAGE_SIZE_OPTIONS, pageSize]))
                .sort((a, b) => a - b)
                .map((n) => (
                  <option key={n} value={n}>
                    {n} per page
                  </option>
                ))}
            </select>
          </div>
          {/* `-pagination` names exactly the pagination, which is what the
              callers asserting on it have always meant by it. */}
          {showPageNav && (
            <div
              style={{ display: 'flex', alignItems: 'center', gap: 6 }}
              data-testid={`${testIdPrefix}-pagination`}
            >
              <button
                className="btn btn-secondary"
                style={{ fontSize: 11, padding: '3px 10px' }}
                disabled={safePage <= 1}
                onClick={() => setPage((p) => Math.max(1, p - 1))}
                data-testid={`${testIdPrefix}-prev`}
              >
                Previous
              </button>
              <span data-testid={`${testIdPrefix}-page-indicator`}>
                Page {safePage} of {totalPages}
              </span>
              <button
                className="btn btn-secondary"
                style={{ fontSize: 11, padding: '3px 10px' }}
                disabled={safePage >= totalPages}
                onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
                data-testid={`${testIdPrefix}-next`}
              >
                Next
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

// ── Exported style constants for renderRow consumers ────────────────────────

DataTable.th = thStyle
DataTable.td = tdStyle

// ── usePrevious hook (inline to avoid external dep) ─────────────────────────

function usePrevious<T>(value: T): T | undefined {
  const ref = useRef<T>()
  useEffect(() => {
    ref.current = value
  })
  return ref.current
}
