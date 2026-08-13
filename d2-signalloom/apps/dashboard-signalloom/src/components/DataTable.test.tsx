import { describe, it, expect } from 'vitest'
import { render, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
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

  // Column help is the mechanism every hinted table on the dashboard rides on,
  // so it is pinned here once rather than re-proved per page.
  describe('column help hints', () => {
    const HELPED: Column<TestRow>[] = [
      { key: 'name', label: 'Name', sortable: true },
      { key: 'score', label: 'Score', sortable: true, help: 'Higher is better.' },
      { key: 'status', label: 'Status' },
    ]

    it('renders a "?" only for columns that declare help', async () => {
      const user = userEvent.setup()
      const { getByRole, queryByRole } = render(
        <DataTable columns={HELPED} data={makeRows(3)} renderRow={renderRow} testIdPrefix="h" />,
      )

      // A "?" on every header would be noise; only the column that earns one gets one.
      expect(queryByRole('button', { name: 'What Name means' })).toBeNull()
      expect(queryByRole('button', { name: 'What Status means' })).toBeNull()

      const hint = getByRole('button', { name: 'What Score means' })
      await user.hover(hint)
      expect(getByRole('tooltip')).toHaveTextContent('Higher is better.')
    })

    it('is reachable by keyboard and names itself for a screen reader', async () => {
      const user = userEvent.setup()
      const { getByRole } = render(
        <DataTable columns={HELPED} data={makeRows(3)} renderRow={renderRow} testIdPrefix="h" />,
      )

      const hint = getByRole('button', { name: 'What Score means' })
      // Tab from the document body: the "?" is the only focusable thing in
      // this table, so reaching it proves it is not mouse-only.
      await user.tab()
      expect(document.activeElement).toBe(hint)

      const tooltip = getByRole('tooltip')
      expect(hint.getAttribute('aria-describedby')).toBe(tooltip.id)
    })

    it('does not sort the table when the "?" inside a sortable header is clicked', () => {
      const data = makeRows(3)
      const { getByRole, getByText, container } = render(
        <DataTable columns={HELPED} data={data} renderRow={renderRow} testIdPrefix="h" />,
      )

      const firstBefore = container.querySelectorAll('tbody tr')[0].textContent
      // The sort handler lives on the `th`; without stopPropagation this click
      // would silently re-order the table the viewer is reading.
      fireEvent.click(getByRole('button', { name: 'What Score means' }))
      expect(container.querySelectorAll('tbody tr')[0].textContent).toBe(firstBefore)

      // The header itself still sorts — the guard is scoped to the hint.
      fireEvent.click(getByText('Score'))
      expect(container.querySelectorAll('tbody tr')[0].textContent).not.toBe(firstBefore)
    })
  })

  // ── toolbar and emptyState ────────────────────────────────────────────────
  //
  // These two are why there is one DataTable and not a `DataTableFiltered`
  // beside it. The predicate stays with the caller, because AgentsPage and
  // CredentialInventoryPage define "search" differently and always will. What
  // these share is the chrome and one bug, and the bug is the whole reason
  // `toolbar` is a prop rather than something a page stacks above the table.

  describe('toolbar and emptyState', () => {
    const toolbar = <input aria-label="Search" data-testid="tb-search" />
    const empty = <p data-testid="tb-empty-copy">Nothing matches that search.</p>

    it('adds neither unless asked, so an existing call site is untouched', () => {
      const { queryByTestId } = render(
        <DataTable columns={COLUMNS} data={makeRows(3)} renderRow={renderRow} testIdPrefix="bare" />,
      )
      expect(queryByTestId('bare-toolbar')).toBeNull()
      expect(queryByTestId('bare-empty')).toBeNull()
    })

    it('renders the toolbar above the table and reads nothing in it', () => {
      const { getByTestId, container } = render(
        <DataTable
          columns={COLUMNS}
          data={makeRows(3)}
          renderRow={renderRow}
          toolbar={toolbar}
          testIdPrefix="tb"
        />,
      )
      const slot = getByTestId('tb-toolbar')
      expect(slot).toContainElement(getByTestId('tb-search'))
      // A slot, not a feature: typing in it filters nothing, because the
      // predicate belongs to the caller. All three rows are still here.
      fireEvent.change(getByTestId('tb-search'), { target: { value: 'row-00' } })
      expect(container.querySelectorAll('tbody tr')).toHaveLength(3)
      // Above the table in DOM order, which is what makes it read as a control
      // FOR the table rather than a caption under it.
      const table = container.querySelector('table') as HTMLElement
      expect(slot.compareDocumentPosition(table) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    })

    it('swaps the table for the empty state when the data runs out', () => {
      const { getByTestId, container } = render(
        <DataTable columns={COLUMNS} data={[]} renderRow={renderRow} emptyState={empty} testIdPrefix="tb" />,
      )
      expect(getByTestId('tb-empty-copy')).toBeInTheDocument()
      // Headers over zero rows is a table pretending to be a table.
      expect(container.querySelector('table')).toBeNull()
    })

    it('keeps the toolbar when the table is replaced by the empty state', () => {
      // THE assertion. A hand-rolled `rows.length ? <Table/> : <Empty/>`
      // ternary takes the search box down with the table, and the user is left
      // with no way to undo the filter that emptied it short of a reload.
      // Inside DataTable the toolbar renders on the empty branch by
      // construction, so a caller cannot get this wrong.
      const { getByTestId } = render(
        <DataTable
          columns={COLUMNS}
          data={[]}
          renderRow={renderRow}
          toolbar={toolbar}
          emptyState={empty}
          testIdPrefix="tb"
        />,
      )
      expect(getByTestId('tb-toolbar')).toBeInTheDocument()
      expect(getByTestId('tb-search')).toBeInTheDocument()
      expect(getByTestId('tb-empty-copy')).toBeInTheDocument()
    })

    it('goes back to the table when rows return', () => {
      const { rerender, queryByTestId, container } = render(
        <DataTable
          columns={COLUMNS}
          data={[]}
          renderRow={renderRow}
          toolbar={toolbar}
          emptyState={empty}
          testIdPrefix="tb"
        />,
      )
      rerender(
        <DataTable
          columns={COLUMNS}
          data={makeRows(3)}
          renderRow={renderRow}
          toolbar={toolbar}
          emptyState={empty}
          testIdPrefix="tb"
        />,
      )
      expect(queryByTestId('tb-empty-copy')).toBeNull()
      expect(container.querySelectorAll('tbody tr')).toHaveLength(3)
      expect(queryByTestId('tb-toolbar')).toBeInTheDocument()
    })

    it('leaves the old behaviour alone when emptyState is omitted', () => {
      // Opt-in: a caller that already handles emptiness its own way keeps
      // rendering headers over no rows exactly as it does today.
      const { container } = render(
        <DataTable columns={COLUMNS} data={[]} renderRow={renderRow} testIdPrefix="tb" />,
      )
      expect(container.querySelector('table')).not.toBeNull()
      expect(container.querySelectorAll('tbody tr')).toHaveLength(0)
    })

    it('shows no pager over an empty state', () => {
      const { queryByTestId } = render(
        <DataTable
          columns={COLUMNS}
          data={[]}
          renderRow={renderRow}
          emptyState={empty}
          hidePaginationWhenSinglePage={false}
          testIdPrefix="tb"
        />,
      )
      // "Page 1 of 1 · No rows" under a panel that already says nothing matched
      // is furniture restating a fact.
      expect(queryByTestId('tb-pagination')).toBeNull()
    })
  })

  // ── the footer and the page navigation are two different questions ────────
  //
  // They used to be one boolean, and the one it was is what made the
  // rows-per-page select a one-way door: `sorted.length > pageSize` reads the
  // select's OWN value, so choosing a size at or above the row count unmounted
  // the footer that held the select. The control vanished as a direct
  // consequence of being used, and nothing but a reload brought it back.
  //
  // The severity is not that a control is hidden. It is that the control hides
  // ITSELF, which is a state the user cannot leave. So the rule these tests
  // pin is narrow and absolute: a control's own value never decides whether
  // that control renders.

  describe('rows-per-page is not a one-way door', () => {
    it('keeps the select, its new value and the count when the chosen size swallows every row', () => {
      const data = makeRows(15)
      const { getByTestId, queryByTestId } = render(
        <DataTable columns={COLUMNS} data={data} pageSize={10} renderRow={renderRow} testIdPrefix="ow" />,
      )
      expect(getByTestId('ow-pagination')).toBeTruthy()

      // 25 ≥ 15 rows: the value that used to take the whole footer with it.
      fireEvent.change(getByTestId('ow-page-size'), { target: { value: '25' } })

      const select = getByTestId('ow-page-size') as HTMLSelectElement
      expect(select).toBeInTheDocument()
      expect(select.value).toBe('25')
      expect(getByTestId('ow-footer').textContent).toContain('1–15 of 15')
      // The page navigation is the only part with nothing left to do.
      expect(queryByTestId('ow-pagination')).toBeNull()

      // The door swings back, which is the whole point of it not being a door.
      fireEvent.change(select, { target: { value: '10' } })
      expect((getByTestId('ow-page-size') as HTMLSelectElement).value).toBe('10')
      expect(getByTestId('ow-pagination')).toBeTruthy()
    })

    it('clamps to the first page and still shows the new size when the size grows underneath page 3', () => {
      const data = makeRows(30)
      const { getByTestId, queryByTestId } = render(
        <DataTable columns={COLUMNS} data={data} pageSize={10} renderRow={renderRow} testIdPrefix="cl" />,
      )
      fireEvent.click(getByTestId('cl-next'))
      fireEvent.click(getByTestId('cl-next'))
      expect(getByTestId('cl-page-indicator').textContent).toBe('Page 3 of 3')

      fireEvent.change(getByTestId('cl-page-size'), { target: { value: '50' } })

      expect((getByTestId('cl-page-size') as HTMLSelectElement).value).toBe('50')
      expect(queryByTestId('cl-pagination')).toBeNull()
      // Clamped to the top of the list rather than stranded past the end.
      expect(getByTestId('cl-footer').textContent).toContain('1–30 of 30')
    })

    it('shows the count and the size control on a single-page table, but no page navigation', () => {
      const { getByTestId, queryByTestId } = render(
        <DataTable columns={COLUMNS} data={makeRows(3)} renderRow={renderRow} testIdPrefix="sm" />,
      )
      // `hidePaginationWhenSinglePage` means what its name says: it hides the
      // PAGINATION. "Page 1 of 1" between two dead buttons is the tautology it
      // exists to suppress. How many rows there are is not a tautology.
      expect(queryByTestId('sm-pagination')).toBeNull()
      expect(getByTestId('sm-page-size')).toBeTruthy()
      expect(getByTestId('sm-footer').textContent).toContain('1–3 of 3')
    })

    it('shows page navigation as soon as there is more than one page', () => {
      const { getByTestId } = render(
        <DataTable columns={COLUMNS} data={makeRows(11)} renderRow={renderRow} pageSize={10} testIdPrefix="mp" />,
      )
      expect(getByTestId('mp-pagination')).toBeTruthy()
      expect(getByTestId('mp-page-indicator').textContent).toBe('Page 1 of 2')
    })

    it('suppresses the entire footer over an empty state', () => {
      const { queryByTestId } = render(
        <DataTable
          columns={COLUMNS}
          data={[]}
          renderRow={renderRow}
          emptyState={<p>Nothing matches that search.</p>}
          hidePaginationWhenSinglePage={false}
          testIdPrefix="es"
        />,
      )
      // Nothing to size, nothing to count, nothing to page through.
      expect(queryByTestId('es-footer')).toBeNull()
      expect(queryByTestId('es-pagination')).toBeNull()
      expect(queryByTestId('es-page-size')).toBeNull()
    })

    it('renders no footer when there are no rows at all, even without an empty state', () => {
      const { queryByTestId, container } = render(
        <DataTable
          columns={COLUMNS}
          data={[]}
          renderRow={renderRow}
          hidePaginationWhenSinglePage={false}
          testIdPrefix="nr"
        />,
      )
      // The old headers-over-nothing branch is untouched…
      expect(container.querySelector('table')).not.toBeNull()
      // …but a size control over zero rows controls nothing.
      expect(queryByTestId('nr-footer')).toBeNull()
    })
  })

  it('exports th and td style constants', () => {
    expect(DataTable.th).toBeDefined()
    expect(DataTable.td).toBeDefined()
    expect(DataTable.th.textTransform).toBe('uppercase')
    expect(DataTable.td.fontSize).toBe(13)
  })
})
