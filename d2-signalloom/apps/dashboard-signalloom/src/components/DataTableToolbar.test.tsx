import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import {
  DataTableToolbar,
  ToolbarSearch,
  ToolbarFacet,
  ToolbarSelect,
  ToolbarClear,
  ToolbarCount,
} from './DataTableToolbar'

// The converged filter strip, extracted from six dialects that six agents wrote
// against nine superadmin pages in one day. What is asserted here is exactly
// what the survey found they agree on — and nothing they do not.
//
// The load-bearing negative: this component NEVER sees a row. There is no
// `data` prop, no predicate, no comparator, no count arithmetic. Everything is
// a value or a callback handed down. Several assertions below exist only to pin
// that down, because the tempting next commit is the one that adds `rows` and
// `searchKeys` and turns a layout into a framework.

const FACETS = [
  { value: 'all', count: 18 },
  { value: 'live', count: 8 },
  { value: 'config', count: 6 },
  { value: 'demo', count: 4 },
]

const OWNERS = [
  { value: 'all', label: 'all owners', count: 18 },
  { value: 'identity', label: 'identity', count: 4 },
  { value: 'network', label: 'network', count: 4 },
]

describe('DataTableToolbar', () => {
  it('is a named group, so a screen reader can say what the strip filters', () => {
    render(<DataTableToolbar label="Filter the services"><span>x</span></DataTableToolbar>)
    expect(screen.getByRole('group', { name: 'Filter the services' })).toBeInTheDocument()
  })

  it('renders whatever it is handed, in the order it is handed', () => {
    // A slot, not a schema. Collusion & Access needed a HelpHint between the
    // facet label and the chips; NetworkTests needed a disclosure after the
    // count. A component with four named slots would have had to grow two more.
    render(
      <DataTableToolbar label="Filter">
        <span data-testid="first">1</span>
        <span data-testid="second">2</span>
      </DataTableToolbar>,
    )
    const group = screen.getByRole('group', { name: 'Filter' })
    const order = [...group.children].map((c) => c.getAttribute('data-testid'))
    expect(order).toEqual(['first', 'second'])
  })
})

describe('ToolbarSearch', () => {
  it('carries an accessible name, because it has no visible label to carry one', () => {
    render(<ToolbarSearch label="Search the services" placeholder="Search…" value="" onChange={() => {}} testId="t-search" />)
    const box = screen.getByTestId('t-search')
    expect(box).toHaveAttribute('type', 'search')
    expect(screen.getByLabelText('Search the services')).toBe(box)
  })

  it('reports keystrokes and holds no state of its own', () => {
    const onChange = vi.fn()
    render(<ToolbarSearch label="Search" placeholder="…" value="fixed" onChange={onChange} testId="t-search" />)
    fireEvent.change(screen.getByTestId('t-search'), { target: { value: 'mesh' } })

    expect(onChange).toHaveBeenCalledWith('mesh')
    // Still showing the prop, not the keystroke: the caller owns the value, and
    // a component that quietly kept its own copy would drift from the array it
    // is supposed to describe.
    expect(screen.getByTestId('t-search')).toHaveValue('fixed')
  })
})

describe('ToolbarFacet', () => {
  it('is a group WITHIN the strip, with its own name', () => {
    render(
      <DataTableToolbar label="Filter the services">
        <ToolbarFacet label="Filter the services by source" value="all" options={FACETS} onChange={() => {}} testIdPrefix="t-src" />
      </DataTableToolbar>,
    )
    // Two facets under one flat group announce as a single undifferentiated
    // list. FederatedServicesPage arrived at this nesting independently at
    // 06d60cf before that strip was replaced.
    const outer = screen.getByRole('group', { name: 'Filter the services' })
    expect(within(outer).getByRole('group', { name: 'Filter the services by source' })).toBeInTheDocument()
  })

  it('says which chip is pressed, and never labels over the visible word', () => {
    render(<ToolbarFacet label="By source" value="live" options={FACETS} onChange={() => {}} testIdPrefix="t-src" />)

    expect(screen.getByTestId('t-src-live')).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('t-src-demo')).toHaveAttribute('aria-pressed', 'false')
    // No aria-label at all: the visible text IS the name, so a speech-input
    // user saying "live" reaches the control they can see.
    expect(screen.getByTestId('t-src-live')).not.toHaveAttribute('aria-label')
    expect(screen.getByRole('button', { name: /live/i })).toBe(screen.getByTestId('t-src-live'))
  })

  it('shows each option’s count without computing one', () => {
    render(<ToolbarFacet label="By source" value="all" options={FACETS} onChange={() => {}} testIdPrefix="t-src" />)
    // Handed down, not derived. A facet that counted the rows it can see would
    // read 0 for every option not selected and stop being a way back.
    expect(screen.getByTestId('t-src-config')).toHaveTextContent('config')
    expect(screen.getByTestId('t-src-config')).toHaveTextContent('6')
  })

  it('reports the chosen value to the caller', () => {
    const onChange = vi.fn()
    render(<ToolbarFacet label="By source" value="all" options={FACETS} onChange={onChange} testIdPrefix="t-src" />)
    fireEvent.click(screen.getByTestId('t-src-demo'))
    expect(onChange).toHaveBeenCalledWith('demo')
  })
})

describe('ToolbarSelect', () => {
  it('composes its accessible name from its own visible label', () => {
    render(<ToolbarSelect label="Owner" subject="the services" value="all" options={OWNERS} onChange={() => {}} testId="t-owner" />)
    const select = screen.getByTestId('t-owner')

    // WCAG 2.5.3. An explicit aria-label REPLACES the wrapping <label>'s text,
    // so it has to contain the visible word — and it is composed rather than
    // written out precisely so it cannot drift from the label beside it.
    expect(select.getAttribute('aria-label')?.toLowerCase()).toContain('owner')
    expect(screen.getByLabelText(/by owner/i)).toBe(select)
  })

  it('puts the count in the option text', () => {
    render(<ToolbarSelect label="Owner" subject="services" value="all" options={OWNERS} onChange={() => {}} testId="t-owner" />)
    expect(screen.getByRole('option', { name: 'identity (4)' })).toBeInTheDocument()
  })

  it('omits the parenthesis entirely when an option has no count', () => {
    render(
      <ToolbarSelect
        label="Owner"
        subject="services"
        value="all"
        options={[{ value: 'all', label: 'all owners' }]}
        onChange={() => {}}
        testId="t-owner"
      />,
    )
    // Not "(0)" — an absent count and a count of zero are different facts, and
    // rendering the first as the second invents a measurement.
    expect(screen.getByRole('option', { name: 'all owners' })).toBeInTheDocument()
  })
})

describe('ToolbarClear', () => {
  it('is absent while nothing is narrowing the table', () => {
    render(<ToolbarClear active={false} onClear={() => {}} testId="t-clear" />)
    expect(screen.queryByTestId('t-clear')).not.toBeInTheDocument()
  })

  it('appears once something is, and is named by its visible text', () => {
    const onClear = vi.fn()
    render(<ToolbarClear active onClear={onClear} testId="t-clear" />)
    const button = screen.getByRole('button', { name: 'Clear filters' })
    expect(button).toBe(screen.getByTestId('t-clear'))
    fireEvent.click(button)
    expect(onClear).toHaveBeenCalledTimes(1)
  })
})

describe('ToolbarCount', () => {
  it('states the outcome of every control to its left', () => {
    render(<ToolbarCount shown={4} total={18} testId="t-count" />)
    expect(screen.getByTestId('t-count')).toHaveTextContent('4 of 18 shown')
  })

  it('takes a noun when the table needs one', () => {
    render(<ToolbarCount shown={4} total={18} noun="identities" testId="t-count" />)
    expect(screen.getByTestId('t-count')).toHaveTextContent('4 of 18 identities shown')
  })
})

describe('what this component does not do', () => {
  it('never receives rows, a predicate or a comparator', () => {
    // Asserted against the source rather than the behaviour, because the failure
    // mode is an ADDITION: a future commit that adds `rows` and `searchKeys` to
    // make the call sites shorter would pass every test above. "Search" means
    // name+owner+type on AgentsPage and a clock-dependent status on
    // CredentialInventoryPage, and the two hand-rolled useFilter hooks had
    // already diverged on their signature within a week of each other. Any
    // predicate this component owned would need an escape hatch for the callers
    // it did not fit, which is a fork with extra steps.
    const source = readSource()
    for (const banned of ['rows:', 'data:', 'predicate', 'searchKeys', 'filter(', 'sort(', 'localeCompare']) {
      expect(source, `DataTableToolbar must not contain "${banned}"`).not.toContain(banned)
    }
  })

  it('holds no state', () => {
    const source = readSource()
    for (const banned of ['useState', 'useReducer', 'useMemo', 'useRef']) {
      expect(source, `DataTableToolbar must not call ${banned}`).not.toContain(banned)
    }
  })
})

function readSource(): string {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { readFileSync } = require('node:fs') as typeof import('node:fs')
  const { join } = require('node:path') as typeof import('node:path')
  const raw = readFileSync(join(__dirname, 'DataTableToolbar.tsx'), 'utf8')
  // Comments are stripped first: this file's own comments discuss `predicate`
  // and `useState` at length, and a guard that fired on its own rationale would
  // be unfixable except by deleting the explanation.
  return raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
}
