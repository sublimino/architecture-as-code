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
})
