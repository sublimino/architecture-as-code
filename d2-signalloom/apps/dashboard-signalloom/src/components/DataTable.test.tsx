import { describe, it, expect } from 'vitest'
import { render, fireEvent } from '@testing-library/react'
import DataTable, { type Column } from './DataTable'

interface TestRow {
  name: string
  score: number
  status: string
}

const COLUMNS: Column<TestRow>[] = [
  { key: 'name', label: 'Name', sortable: true },
  { key: 'score', label: 'Score', sortable: true },
  { key: 'status', label: 'Status' },
]

function makeRows(n: number): TestRow[] {
  return Array.from({ length: n }, (_, i) => ({
    name: `row-${String(i).padStart(2, '0')}`,
    score: n - i,
    status: i % 2 === 0 ? 'active' : 'inactive',
  }))
}

function renderRow(item: TestRow) {
  return (
    <tr key={item.name}>
      <td>{item.name}</td>
      <td>{item.score}</td>
      <td>{item.status}</td>
    </tr>
  )
}

describe('DataTable', () => {
  it('renders column headers', () => {
    const { getByText } = render(
      <DataTable columns={COLUMNS} data={makeRows(3)} renderRow={renderRow} />,
    )
    expect(getByText('Name')).toBeTruthy()
    expect(getByText('Score')).toBeTruthy()
    expect(getByText('Status')).toBeTruthy()
  })

  it('renders all rows when data fits in one page', () => {
    const data = makeRows(3)
    const { getByText, queryByTestId } = render(
      <DataTable columns={COLUMNS} data={data} renderRow={renderRow} testIdPrefix="t" />,
    )
    expect(getByText('row-00')).toBeTruthy()
    expect(getByText('row-01')).toBeTruthy()
    expect(getByText('row-02')).toBeTruthy()
    // Pagination hidden when data fits in one page (default hidePaginationWhenSinglePage=true)
    expect(queryByTestId('t-pagination')).toBeNull()
  })

  it('paginates when data exceeds page size', () => {
    const data = makeRows(15)
    const { getByText, queryByText, getByTestId } = render(
      <DataTable columns={COLUMNS} data={data} pageSize={10} renderRow={renderRow} testIdPrefix="p" />,
    )
    // First page shows rows 0-9
    expect(getByText('row-00')).toBeTruthy()
    expect(getByText('row-09')).toBeTruthy()
    expect(queryByText('row-10')).toBeNull()
    expect(getByTestId('p-page-indicator').textContent).toBe('Page 1 of 2')
  })

  it('navigates to next and previous pages', () => {
    const data = makeRows(15)
    const { getByText, queryByText, getByTestId } = render(
      <DataTable columns={COLUMNS} data={data} pageSize={10} renderRow={renderRow} testIdPrefix="n" />,
    )
    // Navigate to page 2
    fireEvent.click(getByTestId('n-next'))
    expect(getByText('row-10')).toBeTruthy()
    expect(queryByText('row-00')).toBeNull()
    expect(getByTestId('n-page-indicator').textContent).toBe('Page 2 of 2')

    // Navigate back
    fireEvent.click(getByTestId('n-prev'))
    expect(getByText('row-00')).toBeTruthy()
    expect(queryByText('row-10')).toBeNull()
    expect(getByTestId('n-page-indicator').textContent).toBe('Page 1 of 2')
  })

  it('disables Previous on first page and Next on last page', () => {
    const data = makeRows(15)
    const { getByTestId } = render(
      <DataTable columns={COLUMNS} data={data} pageSize={10} renderRow={renderRow} testIdPrefix="d" />,
    )
    expect((getByTestId('d-prev') as HTMLButtonElement).disabled).toBe(true)
    expect((getByTestId('d-next') as HTMLButtonElement).disabled).toBe(false)

    fireEvent.click(getByTestId('d-next'))
    expect((getByTestId('d-prev') as HTMLButtonElement).disabled).toBe(false)
    expect((getByTestId('d-next') as HTMLButtonElement).disabled).toBe(true)
  })

  it('sorts ascending then descending on column click', () => {
    const data: TestRow[] = [
      { name: 'charlie', score: 3, status: 'active' },
      { name: 'alice', score: 1, status: 'active' },
      { name: 'bravo', score: 2, status: 'inactive' },
    ]
    const { getByText, container } = render(
      <DataTable columns={COLUMNS} data={data} renderRow={renderRow} />,
    )

    // Click Name to sort ascending
    fireEvent.click(getByText('Name'))
    let rows = container.querySelectorAll('tbody tr')
    expect(rows[0].textContent).toContain('alice')
    expect(rows[1].textContent).toContain('bravo')
    expect(rows[2].textContent).toContain('charlie')

    // Click again for descending
    fireEvent.click(getByText('Name'))
    rows = container.querySelectorAll('tbody tr')
    expect(rows[0].textContent).toContain('charlie')
    expect(rows[1].textContent).toContain('bravo')
    expect(rows[2].textContent).toContain('alice')

    // Third click clears sort (back to original order)
    fireEvent.click(getByText('Name'))
    rows = container.querySelectorAll('tbody tr')
    expect(rows[0].textContent).toContain('charlie')
    expect(rows[1].textContent).toContain('alice')
    expect(rows[2].textContent).toContain('bravo')
  })

  it('sorts numerically for number fields', () => {
    const data: TestRow[] = [
      { name: 'a', score: 100, status: 'active' },
      { name: 'b', score: 2, status: 'active' },
      { name: 'c', score: 30, status: 'inactive' },
    ]
    const { getByText, container } = render(
      <DataTable columns={COLUMNS} data={data} renderRow={renderRow} />,
    )

    fireEvent.click(getByText('Score'))
    const rows = container.querySelectorAll('tbody tr')
    // Ascending: 2, 30, 100
    expect(rows[0].textContent).toContain('2')
    expect(rows[1].textContent).toContain('30')
    expect(rows[2].textContent).toContain('100')
  })

  it('does not sort when clicking a non-sortable column', () => {
    const data: TestRow[] = [
      { name: 'c', score: 3, status: 'active' },
      { name: 'a', score: 1, status: 'inactive' },
    ]
    const { getByText, container } = render(
      <DataTable columns={COLUMNS} data={data} renderRow={renderRow} />,
    )

    // Click Status (not sortable)
    fireEvent.click(getByText('Status'))
    const rows = container.querySelectorAll('tbody tr')
    // Order unchanged
    expect(rows[0].textContent).toContain('c')
    expect(rows[1].textContent).toContain('a')
  })

  it('changes page size via select', () => {
    const data = makeRows(30)
    const { getByTestId, queryByText } = render(
      <DataTable columns={COLUMNS} data={data} pageSize={10} renderRow={renderRow} testIdPrefix="ps" />,
    )
    expect(getByTestId('ps-page-indicator').textContent).toBe('Page 1 of 3')

    // Change to 25 per page
    fireEvent.change(getByTestId('ps-page-size'), { target: { value: '25' } })
    expect(getByTestId('ps-page-indicator').textContent).toBe('Page 1 of 2')

    // Change to 50 per page — all fit on one page, pagination hidden
    fireEvent.change(getByTestId('ps-page-size'), { target: { value: '50' } })
    expect(queryByText('Page 1 of 1')).toBeNull() // hidden because hidePaginationWhenSinglePage
  })

  it('shows pagination when hidePaginationWhenSinglePage is false', () => {
    const data = makeRows(3)
    const { getByTestId } = render(
      <DataTable
        columns={COLUMNS}
        data={data}
        renderRow={renderRow}
        hidePaginationWhenSinglePage={false}
        testIdPrefix="show"
      />,
    )
    expect(getByTestId('show-pagination')).toBeTruthy()
  })

  it('handles empty data', () => {
    const { container } = render(
      <DataTable columns={COLUMNS} data={[]} renderRow={renderRow} testIdPrefix="empty" />,
    )
    const rows = container.querySelectorAll('tbody tr')
    expect(rows.length).toBe(0)
  })

  it('handles null values in sorted columns', () => {
    interface NullableRow { name: string | null; score: number }
    const cols: Column<NullableRow>[] = [
      { key: 'name', label: 'Name', sortable: true },
      { key: 'score', label: 'Score' },
    ]
    const data: NullableRow[] = [
      { name: null, score: 1 },
      { name: 'alice', score: 2 },
      { name: null, score: 3 },
    ]
    const { getByText, container } = render(
      <DataTable
        columns={cols}
        data={data}
        renderRow={(item) => (
          <tr key={item.score}>
            <td>{item.name ?? 'null'}</td>
            <td>{item.score}</td>
          </tr>
        )}
      />,
    )

    // Should not throw when sorting a column with null values
    fireEvent.click(getByText('Name'))
    const rows = container.querySelectorAll('tbody tr')
    expect(rows.length).toBe(3)
    // alice should sort first (asc), nulls pushed to end
    expect(rows[0].textContent).toContain('alice')
  })

  it('exports th and td style constants', () => {
    expect(DataTable.th).toBeDefined()
    expect(DataTable.td).toBeDefined()
    expect(DataTable.th.textTransform).toBe('uppercase')
    expect(DataTable.td.fontSize).toBe(13)
  })
})
