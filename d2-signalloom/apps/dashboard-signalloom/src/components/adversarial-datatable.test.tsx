/**
 * Adversarial tests for DataTable — edge cases the happy-path suite does not
 * cover. Each test feeds data that is technically valid per the TypeScript types
 * but exercises paths the existing 2166 tests never reach.
 *
 * Round 3 adversarial testing.
 */
import { describe, it, expect } from 'vitest'
import { render, fireEvent } from '@testing-library/react'
import DataTable, { type Column } from './DataTable'

// ── Helpers ─────────────────────────────────────────────────────────────────

interface Row {
  name: string
  score: number
  status: string
}

const COLUMNS: Column<Row>[] = [
  { key: 'name', label: 'Name', sortable: true },
  { key: 'score', label: 'Score', sortable: true },
  { key: 'status', label: 'Status' },
]

function renderRow(item: Row) {
  return (
    <tr key={item.name}>
      <td>{item.name}</td>
      <td>{item.score}</td>
      <td>{item.status}</td>
    </tr>
  )
}

function makeTable(data: Row[], opts?: { pageSize?: number; testIdPrefix?: string }) {
  return render(
    <DataTable
      columns={COLUMNS}
      data={data}
      renderRow={renderRow}
      pageSize={opts?.pageSize ?? 10}
      testIdPrefix={opts?.testIdPrefix ?? 'adv'}
    />,
  )
}

// ── NaN in numeric sort ─────────────────────────────────────────────────────

describe('DataTable — NaN sort stability', () => {
  // BUG: The sort comparator does `(aVal - bVal) * dir` when both values are
  // `typeof === 'number'`. NaN IS a number, and `NaN - x` returns NaN, which
  // makes Array.sort's behaviour implementation-defined. The sort must treat
  // NaN as nullish (push it to the end).
  it('sorts NaN scores to the end in ascending order', () => {
    const data: Row[] = [
      { name: 'c', score: NaN, status: 'ok' },
      { name: 'a', score: 10, status: 'ok' },
      { name: 'b', score: 5, status: 'ok' },
    ]
    const { getByText, getAllByRole } = makeTable(data)

    // Click Score header to sort ascending
    fireEvent.click(getByText('Score'))

    const rows = getAllByRole('row')
    // First data row (index 1, after header) should be score=5 ('b')
    // NaN should sort to the end, not randomly interleave
    const cells = rows.slice(1).map(r => r.querySelectorAll('td'))
    const names = Array.from(cells).map(c => c[0]?.textContent)

    // b (5), a (10) should come first; c (NaN) should be last
    expect(names[0]).toBe('b')
    expect(names[1]).toBe('a')
    expect(names[2]).toBe('c')
  })

  it('sorts NaN scores to the end in descending order', () => {
    const data: Row[] = [
      { name: 'c', score: NaN, status: 'ok' },
      { name: 'a', score: 10, status: 'ok' },
      { name: 'b', score: 5, status: 'ok' },
    ]
    const { getByText, getAllByRole } = makeTable(data)

    // Click Score header twice to sort descending
    fireEvent.click(getByText('Score'))
    fireEvent.click(getByText('Score'))

    const rows = getAllByRole('row')
    const cells = rows.slice(1).map(r => r.querySelectorAll('td'))
    const names = Array.from(cells).map(c => c[0]?.textContent)

    // a (10), b (5) should come first; c (NaN) should be last
    expect(names[0]).toBe('a')
    expect(names[1]).toBe('b')
    expect(names[2]).toBe('c')
  })
})

// ── Unicode and special strings ─────────────────────────────────────────────

describe('DataTable — Unicode and special characters', () => {
  it('renders RTL text without crashing', () => {
    const data: Row[] = [
      { name: 'مرحبا', score: 1, status: 'ok' },
      { name: 'שלום', score: 2, status: 'ok' },
    ]
    const { getByText } = makeTable(data)
    expect(getByText('مرحبا')).toBeTruthy()
    expect(getByText('שלום')).toBeTruthy()
  })

  it('renders emoji in data without crashing', () => {
    const data: Row[] = [
      { name: 'Agent 🔥', score: 1, status: '✅' },
    ]
    const { getByText } = makeTable(data)
    expect(getByText('Agent 🔥')).toBeTruthy()
  })

  it('renders very long strings without throwing', () => {
    const longName = 'A'.repeat(10000)
    const data: Row[] = [{ name: longName, score: 1, status: 'ok' }]
    // Should not throw
    const { container } = makeTable(data)
    expect(container.textContent).toContain(longName)
  })

  it('renders strings containing HTML-like content safely', () => {
    const xssPayload = '<img src=x onerror=alert(1)>'
    const data: Row[] = [{ name: xssPayload, score: 1, status: 'ok' }]
    const { container } = makeTable(data)
    // React escapes the string, so it should appear as text, not as an element
    expect(container.querySelector('img')).toBeNull()
    expect(container.textContent).toContain(xssPayload)
  })

  it('sorts strings with mixed case correctly', () => {
    const data: Row[] = [
      { name: 'Zebra', score: 1, status: 'ok' },
      { name: 'apple', score: 2, status: 'ok' },
      { name: 'Banana', score: 3, status: 'ok' },
    ]
    const { getByText, getAllByRole } = makeTable(data)
    fireEvent.click(getByText('Name'))

    const rows = getAllByRole('row')
    const names = rows.slice(1).map(r => r.querySelectorAll('td')[0]?.textContent)
    // Case-insensitive sort: apple, Banana, Zebra
    expect(names).toEqual(['apple', 'Banana', 'Zebra'])
  })
})

// ── Empty and extreme data ──────────────────────────────────────────────────

describe('DataTable — empty and extreme data', () => {
  it('renders headers but no rows for empty data', () => {
    const { getByText, getAllByRole } = makeTable([])
    expect(getByText('Name')).toBeTruthy()
    // Only header row
    expect(getAllByRole('row')).toHaveLength(1)
  })

  it('renders a single row correctly', () => {
    const data: Row[] = [{ name: 'solo', score: 42, status: 'ok' }]
    const { getByText, queryByTestId } = makeTable(data, { testIdPrefix: 'solo' })
    expect(getByText('solo')).toBeTruthy()
    // No pagination for single row
    expect(queryByTestId('solo-pagination')).toBeNull()
  })

  it('handles pageSize larger than data length', () => {
    const data: Row[] = [{ name: 'a', score: 1, status: 'ok' }]
    const { getByText, queryByTestId } = makeTable(data, { pageSize: 100, testIdPrefix: 'big' })
    expect(getByText('a')).toBeTruthy()
    expect(queryByTestId('big-pagination')).toBeNull()
  })

  it('handles negative scores correctly', () => {
    const data: Row[] = [
      { name: 'neg', score: -100, status: 'ok' },
      { name: 'pos', score: 100, status: 'ok' },
      { name: 'zero', score: 0, status: 'ok' },
    ]
    const { getByText, getAllByRole } = makeTable(data)
    fireEvent.click(getByText('Score'))

    const rows = getAllByRole('row')
    const scores = rows.slice(1).map(r => r.querySelectorAll('td')[1]?.textContent)
    expect(scores).toEqual(['-100', '0', '100'])
  })

  it('handles Infinity scores without crashing', () => {
    const data: Row[] = [
      { name: 'inf', score: Infinity, status: 'ok' },
      { name: 'ninf', score: -Infinity, status: 'ok' },
      { name: 'normal', score: 5, status: 'ok' },
    ]
    const { getByText, getAllByRole } = makeTable(data)
    fireEvent.click(getByText('Score'))

    const rows = getAllByRole('row')
    const names = rows.slice(1).map(r => r.querySelectorAll('td')[0]?.textContent)
    // -Infinity should sort before 5 before Infinity
    expect(names).toEqual(['ninf', 'normal', 'inf'])
  })
})

// ── Toolbar survives empty state ────────────────────────────────────────────

describe('DataTable — toolbar persists through empty state', () => {
  it('renders toolbar when data is empty and emptyState is provided', () => {
    const { getByTestId, getByText } = render(
      <DataTable
        columns={COLUMNS}
        data={[]}
        renderRow={renderRow}
        testIdPrefix="tb"
        toolbar={<input placeholder="Search..." />}
        emptyState={<div>Nothing here</div>}
      />,
    )
    expect(getByTestId('tb-toolbar')).toBeTruthy()
    expect(getByText('Nothing here')).toBeTruthy()
  })
})
