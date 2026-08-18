/**
 * Tests for AuditTrail CSV export button and clickable event-type chip filters.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import AuditTrail from './AuditTrail'
import { api } from '../api/client'

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

vi.mock('../api/client', () => ({
  api: {
    audit: vi.fn(),
    auditExportCsv: vi.fn(),
  },
}))

const EVENTS = [
  {
    id: 'evt-1',
    timestamp: '2026-07-01T12:00:00Z',
    event_type: 'token_issued',
    agent_id: 'agent-1',
    agent_name: 'agent-one',
    actor: 'operator@signal-loom.ai',
    detail: {},
  },
  {
    id: 'evt-2',
    timestamp: '2026-07-01T12:05:00Z',
    event_type: 'violation_detected',
    agent_id: 'agent-2',
    agent_name: 'agent-two',
    actor: 'operator@signal-loom.ai',
    detail: {},
  },
]

/**
 * A third event so the three tiers of narrowing are distinguishable.
 *
 * `token_issued` is routine, `violation_detected` is enforcement and
 * `nhi.dismissed` is attention — three classes across three rows, so a chip
 * that filtered on the wrong axis, or on nothing, would leave a row count that
 * matches by accident on none of them.
 */
const THIRD = {
  id: 'evt-3',
  timestamp: '2026-07-01T12:09:00Z',
  event_type: 'nhi.dismissed',
  agent_id: 'agent-3',
  agent_name: 'zebra-agent',
  actor: 'auditor@signal-loom.ai',
  detail: { reason: 'superseded' },
}

const THREE = [...EVENTS, THIRD]

/**
 * The event types the TABLE is currently rendering, in render order.
 *
 * Scoped to the tbody, because every type is also an `<option>` in the strip's
 * select and a document-wide text query would happily match the dropdown — the
 * hazard AuditTrail.tsx documents against its own EVENT_TYPES list.
 */
function renderedTypes(): string[] {
  const body = screen.getByRole('table').querySelector('tbody') as HTMLElement
  return Array.from(body.querySelectorAll('tr')).map(
    (tr) => (tr.querySelector('td:nth-child(2)') as HTMLElement).textContent ?? '',
  )
}

function setup() {
  vi.mocked(api.audit).mockResolvedValue({ events: EVENTS, total: EVENTS.length, page: 1, limit: 50 } as never)
  vi.mocked(api.auditExportCsv).mockResolvedValue('id,timestamp\nevt-1,2026-07-01T12:00:00Z' as never)
}

beforeEach(() => {
  vi.clearAllMocks()
  setup()
  // jsdom doesn't implement Blob URLs — stub them so the download flow doesn't throw.
  global.URL.createObjectURL = vi.fn().mockReturnValue('blob:mock')
  global.URL.revokeObjectURL = vi.fn()
})

// The two questions this page reliably prompts, answered on the page rather than
// in a document nobody reading a table has open. Asserted on the copy, not merely
// on the presence of a hint, because a "?" that explains nothing is the failure
// mode worth catching.
describe('AuditTrail — explains itself', () => {
  it('says rows are written by the server and cannot be altered', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)

    await user.hover(screen.getByTestId('audit-page-help'))

    const tip = await screen.findByRole('tooltip')
    expect(tip.textContent).toContain('nothing here was submitted by a browser')
    expect(tip.textContent).toContain('cannot be edited or')
  })

  it('leaves the heading name alone, so the hint is not announced as part of it', async () => {
    render(<AuditTrail />)

    // A HelpHint nested inside the `h1` joins its accessible name. Guarded here
    // because the fix is invisible in the rendered page and trivially undone.
    expect(
      await screen.findByRole('heading', { level: 1, name: 'Audit Trail' }),
    ).toBeInTheDocument()
  })

  it('explains what the Actor column holds, including demo-actor', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)

    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())
    await user.hover(screen.getByTestId('audit-help-actor'))

    const tip = await screen.findByRole('tooltip')
    expect(tip.textContent).toContain('sign-in token')
    expect(tip.textContent).toContain('demo-actor')
  })
})

describe('AuditTrail — CSV export', () => {
  it('exports CSV using the current filters', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)

    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    await user.click(screen.getByRole('button', { name: 'Export CSV' }))

    await waitFor(() => {
      expect(api.auditExportCsv).toHaveBeenCalledWith('test-token', {
        from: undefined,
        to: undefined,
        agent: undefined,
        type: undefined,
      })
    })
    expect(global.URL.createObjectURL).toHaveBeenCalled()
  })

  it('shows an error message if the export fails', async () => {
    vi.mocked(api.auditExportCsv).mockRejectedValue(new Error('boom'))
    const user = userEvent.setup()
    render(<AuditTrail />)

    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())
    await user.click(screen.getByRole('button', { name: 'Export CSV' }))

    await waitFor(() => {
      expect(screen.getByText('Export failed. Please try again.')).toBeInTheDocument()
    })
  })
})

describe('AuditTrail — clickable type chips', () => {
  it('filters the table to the clicked event type', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)

    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())
    vi.mocked(api.audit).mockClear()

    await user.click(screen.getByRole('button', { name: 'token_issued' }))

    await waitFor(() => {
      expect(api.audit).toHaveBeenCalledWith(
        'test-token',
        expect.objectContaining({ type: 'token_issued' }),
      )
    })
  })

  it('toggles the filter off when the same chip is clicked again', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)

    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    await user.click(screen.getByRole('button', { name: 'token_issued' }))
    await waitFor(() => {
      expect(api.audit).toHaveBeenCalledWith(
        'test-token',
        expect.objectContaining({ type: 'token_issued' }),
      )
    })

    vi.mocked(api.audit).mockClear()
    await user.click(screen.getByRole('button', { name: 'token_issued' }))

    await waitFor(() => {
      expect(api.audit).toHaveBeenCalledWith(
        'test-token',
        expect.objectContaining({ type: undefined }),
      )
    })
  })

  it('renders the tags as real buttons, so a keyboard can reach the filter', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    // Was a <span role="button"> with an onClick and no tabIndex: announced as
    // a button, reachable only by mouse. The element type is the assertion —
    // `role=button` alone passed happily for the whole time it was unreachable.
    const tag = screen.getByRole('button', { name: 'token_issued' })
    expect(tag.tagName).toBe('BUTTON')
    expect(tag).toHaveAttribute('aria-pressed', 'false')

    vi.mocked(api.audit).mockClear()
    tag.focus()
    await user.keyboard('{Enter}')

    await waitFor(() => {
      expect(api.audit).toHaveBeenCalledWith(
        'test-token',
        expect.objectContaining({ type: 'token_issued' }),
      )
    })
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'token_issued' })).toHaveAttribute('aria-pressed', 'true'),
    )
  })
})

// ── The migration onto the Design System's third DataTable specimen ─────────
//
// The page now hands DataTable an array it has already narrowed and passes the
// strip through the `toolbar` slot rather than stacking a card above the table.
// Everything below either guards the capability that added, or guards that it
// added nothing — the second being the harder half, because this is a
// compliance surface and a filter that quietly drops a row is worse here than
// a filter that does not work at all.

describe('AuditTrail — the untouched page is the page it always was', () => {
  it('renders every loaded row, in the order the server sent them', async () => {
    vi.mocked(api.audit).mockResolvedValue({ events: THREE, total: THREE.length, page: 1, limit: 50 } as never)
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    // Not a count: the ORDER. DataTable sorts nothing until a header is
    // clicked, and the client-side strip defaults to a no-op, so first paint
    // must be the server's array verbatim. A default sort slipped in anywhere
    // between here and DataTable would reorder an audit trail silently.
    expect(renderedTypes()).toEqual(['token_issued', 'violation_detected', 'nhi.dismissed'])
  })

  it('offers no Clear until there is something to clear', async () => {
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    expect(screen.queryByTestId('audit-clear')).not.toBeInTheDocument()
    expect(screen.queryByTestId('audit-filter-pending')).not.toBeInTheDocument()
  })
})

describe('AuditTrail — the client-side tier hides rows and asks nothing', () => {
  beforeEach(() => {
    vi.mocked(api.audit).mockResolvedValue({ events: THREE, total: THREE.length, page: 1, limit: 50 } as never)
  })

  it('narrows on search without going back to the server', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    const callsBefore = vi.mocked(api.audit).mock.calls.length
    await user.type(screen.getByTestId('audit-search'), 'zebra')

    await waitFor(() => expect(renderedTypes()).toEqual(['nhi.dismissed']))
    // The distinction the strip's rule and both hints exist to make. If this
    // ever fires a request, the count beside it starts lying about which
    // population it measured.
    expect(vi.mocked(api.audit).mock.calls.length).toBe(callsBefore)
    expect(screen.getByTestId('audit-count').textContent).toBe('1 of 3 loaded events shown')
  })

  it('searches the detail payload, which is a column the table renders', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    await user.type(screen.getByTestId('audit-search'), 'superseded')
    await waitFor(() => expect(renderedTypes()).toEqual(['nhi.dismissed']))
  })

  it('narrows on the class chips, which are derived from the tag colours', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    // violation_detected is var(--error) -> enforcement; token_issued is
    // var(--cyan) -> routine; nhi.dismissed is var(--amber) -> attention. One
    // row each, so a chip filtering on the wrong axis cannot match by accident.
    await user.click(screen.getByTestId('audit-class-enforcement'))
    await waitFor(() => expect(renderedTypes()).toEqual(['violation_detected']))

    await user.click(screen.getByTestId('audit-class-attention'))
    await waitFor(() => expect(renderedTypes()).toEqual(['nhi.dismissed']))
  })

  it('counts the whole loaded set on every chip, not the result', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    await user.click(screen.getByTestId('audit-class-enforcement'))
    await waitFor(() => expect(renderedTypes()).toEqual(['violation_detected']))

    // The chips a reader has NOT chosen must keep reporting what they would
    // find. Counted against the result they would all read 0 and stop being a
    // way back to the rows they are hiding.
    expect(screen.getByTestId('audit-class-all').textContent).toContain('3')
    expect(screen.getByTestId('audit-class-routine').textContent).toContain('1')
    expect(screen.getByTestId('audit-class-attention').textContent).toContain('1')
    // Always offered and usually zero: an unrecognised type from a newer
    // server has to land somewhere a reader would think to look.
    expect(screen.getByTestId('audit-class-other').textContent).toContain('0')
  })
})

describe('AuditTrail — the empty result a filter caused', () => {
  beforeEach(() => {
    vi.mocked(api.audit).mockResolvedValue({ events: THREE, total: THREE.length, page: 1, limit: 50 } as never)
  })

  it('says the rows are still here, and leaves two ways back', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    await user.type(screen.getByTestId('audit-search'), 'nothing-matches-this')

    const panel = await screen.findByTestId('audit-filtered-empty')
    // Distinct from "No events found": one says the server holds nothing, the
    // other says this browser is hiding what it holds. Reading the second as
    // the first, on an audit trail, is how a quiet period and a mistyped
    // filter become the same observation.
    expect(panel.textContent).toContain('Nothing matches these filters')
    expect(panel.textContent).toContain('3 loaded events are still here')

    // The bug the toolbar slot exists to make impossible: hand-rolled, the
    // control that emptied the table disappears with it.
    expect(screen.getByTestId('audit-clear')).toBeInTheDocument()
    expect(screen.getByTestId('audit-search')).toBeInTheDocument()
    expect(screen.getByTestId('audit-empty-clear')).toBeInTheDocument()
  })

  it('keeps the server-empty wording for a server that returned nothing', async () => {
    vi.mocked(api.audit).mockResolvedValue({ events: [], total: 0, page: 1, limit: 50 } as never)
    render(<AuditTrail />)

    expect(await screen.findByText('No events found')).toBeInTheDocument()
    expect(screen.queryByTestId('audit-filtered-empty')).not.toBeInTheDocument()
    // Nothing loaded means nothing to say about what was loaded.
    expect(screen.queryByText(/from server/)).not.toBeInTheDocument()
  })

  it('clears both tiers from inside the panel and re-queries the server', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    await user.type(screen.getByTestId('audit-agent'), 'agent-9')
    await user.click(screen.getByTestId('audit-apply'))
    await user.type(screen.getByTestId('audit-search'), 'nothing-matches-this')
    await screen.findByTestId('audit-filtered-empty')

    vi.mocked(api.audit).mockClear()
    await user.click(screen.getByTestId('audit-empty-clear'))

    // "Clear filters" naming only half the filters is the reset that leaves an
    // operator staring at a still-narrowed table.
    await waitFor(() => {
      expect(api.audit).toHaveBeenCalledWith('test-token', expect.objectContaining({ agent: undefined }))
    })
    await waitFor(() => expect(renderedTypes()).toEqual(['token_issued', 'violation_detected', 'nhi.dismissed']))
    expect(screen.getByTestId('audit-search')).toHaveValue('')
  })
})

describe('AuditTrail — the strip is reachable in every state', () => {
  it('keeps the filters on screen while the first page is loading', async () => {
    vi.mocked(api.audit).mockReturnValue(new Promise(() => {}) as never)
    render(<AuditTrail />)

    // The card this replaced was outside the loading branch, and an operator
    // watching a slow fetch is very often already retyping the filter.
    expect(await screen.findByTestId('audit-load-state')).toBeInTheDocument()
    expect(screen.getByTestId('audit-toolbar')).toBeInTheDocument()
    expect(screen.getByTestId('audit-search')).toBeInTheDocument()
  })

  it('keeps the filters on screen when the fetch fails', async () => {
    vi.mocked(api.audit).mockRejectedValue(new Error('boom'))
    render(<AuditTrail />)

    expect(await screen.findByTestId('audit-load-state')).toBeInTheDocument()
    expect(screen.getByTestId('audit-search')).toBeInTheDocument()
    expect(screen.getByTestId('audit-apply')).toBeInTheDocument()
  })
})

describe('AuditTrail — a typed filter that has not been sent says so', () => {
  it('marks the four server controls pending until Apply, then stops', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    await user.type(screen.getByTestId('audit-agent'), 'agent-1')

    // The gap only exists because these four apply on a button. On a page
    // whose whole job is to be believed, a filter that looks applied and is
    // not is the worst failure available to it.
    expect(await screen.findByTestId('audit-filter-pending')).toBeInTheDocument()

    await user.click(screen.getByTestId('audit-apply'))
    await waitFor(() => expect(screen.queryByTestId('audit-filter-pending')).not.toBeInTheDocument())
    expect(api.audit).toHaveBeenCalledWith('test-token', expect.objectContaining({ agent: 'agent-1' }))
  })

  it('does not mark a row-tag click pending, because that one applies itself', async () => {
    const user = userEvent.setup()
    render(<AuditTrail />)
    await waitFor(() => expect(screen.getByText('agent-one')).toBeInTheDocument())

    await user.click(screen.getByRole('button', { name: 'token_issued' }))

    await waitFor(() => {
      expect(api.audit).toHaveBeenCalledWith('test-token', expect.objectContaining({ type: 'token_issued' }))
    })
    // The select and the tag write the same state. If only one of them told
    // the mirror, this page would advertise a pending filter it had already
    // sent, for as long as that filter stayed on.
    expect(screen.queryByTestId('audit-filter-pending')).not.toBeInTheDocument()
  })
})
