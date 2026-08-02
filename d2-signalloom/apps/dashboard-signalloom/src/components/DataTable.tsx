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
 * // TODO: server-side pagination when API supports it
 */
import { useState, useMemo, useCallback, useRef, useEffect, type ReactNode, type CSSProperties } from 'react'

// ── Types ───────────────────────────────────────────────────────────────────

export interface Column<T> {
  /** Key used to access the data field for sorting. */
  key: keyof T & string
  /** Display label in the header. */
  label: string
  /** Whether clicking the header sorts by this column. Default false. */
  sortable?: boolean
}

type SortDir = 'asc' | 'desc' | null

interface SortState {
  key: string
  dir: SortDir
}

export interface DataTableProps<T> {
  columns: Column<T>[]
  data: T[]
  /** Number of rows per page. Default 10. */
  pageSize?: number
  /** Custom row renderer. Receives the item and its index within the full sorted array. */
  renderRow: (item: T, index: number) => ReactNode
  /** Optional: hide pagination when data fits in one page. Default true. */
  hidePaginationWhenSinglePage?: boolean
  /** Optional test-id prefix for pagination controls. */
  testIdPrefix?: string
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

      // Handle nullish
      if (aVal == null && bVal == null) return 0
      if (aVal == null) return dir
      if (bVal == null) return -dir

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

  const showPagination = !hidePaginationWhenSinglePage || sorted.length > pageSize

  return (
    <div>
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
                  {col.label}
                  {col.sortable && <SortArrow dir={sort.key === col.key ? sort.dir : null} />}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {pageData.map((item, i) => renderRow(item, start + i))}
          </tbody>
        </table>
      </div>

      {showPagination && (
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
          data-testid={`${testIdPrefix}-pagination`}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span>
              {sorted.length === 0
                ? 'No rows'
                : `${start + 1}–${Math.min(start + pageSize, sorted.length)} of ${sorted.length}`}
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
              {[10, 25, 50].map((n) => (
                <option key={n} value={n}>
                  {n} per page
                </option>
              ))}
            </select>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
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
