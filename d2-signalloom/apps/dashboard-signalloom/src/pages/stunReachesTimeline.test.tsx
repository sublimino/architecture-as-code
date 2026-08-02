// End-to-end within the browser: press Stun on the SuperCred page, then open
// the Audit Trail and find the event.
//
// Every other test in this change checks one seam — the fixture route, the
// client call, the page's rendering. None of them proves the thing the demo
// audience actually watches: that an action taken on one page shows up on the
// page that claims to be the record of what happened. This does, through the
// real client, the real fixture resolver and the real AuditTrail component.
//
// Demo mode is the mode under test here because it is the one with no backend
// to lean on. The live path's equivalent guarantee is asserted server-side in
// fe-signalloom/src/tests/test_write_transactions.py, where the audit row and
// the lifecycle change are proven to commit or roll back together.

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

import SuperCredPage from './SuperCredPage'
import AuditTrail from '../views/AuditTrail'
import { setDemoMode } from '../api/demoMode'
import { clearDemoActivity } from '../api/demoActivity'

const FLUX_NS = 'fe-signalloom'

const CARDVAULT = {
  id: 'agent-cardvault',
  name: 'Cardvault Agent',
  namespace: FLUX_NS,
  type: 'supercred-demo',
  state: 'idle',
  phase: 'Running',
  supercred: true,
}

function mockProxy() {
  globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
    if (String(input).includes('/stun')) {
      return {
        ok: true,
        json: async () => ({
          agent_id: 'agent-cardvault',
          namespace: FLUX_NS,
          state: 'stunned',
          stunned_at: '2026-08-02T10:00:00Z',
          message: 'Agent agent-cardvault stunned: credentials revoked',
        }),
      } as Response
    }
    return {
      ok: true,
      json: async () => ({ agents: [CARDVAULT], namespaces: [FLUX_NS] }),
    } as Response
  }) as unknown as typeof fetch
}

beforeEach(() => {
  clearDemoActivity()
  getAccessTokenSilently.mockResolvedValue('test-token')
  setDemoMode(true)
  mockProxy()
})

afterEach(() => {
  setDemoMode(false)
  vi.unstubAllGlobals()
})

/** The event type also renders as an <option> in the filter dropdown, so every
 *  query here is scoped to the table body — the trail itself, not the filter. */
async function auditRows(): Promise<HTMLElement> {
  const table = await screen.findByRole('table')
  return table.querySelector('tbody') as HTMLElement
}

/** Press Stun on the SuperCred page, confirm it recorded, then unmount. */
async function stunViaSuperCredPage(): Promise<void> {
  const { unmount } = render(<MemoryRouter><SuperCredPage /></MemoryRouter>)
  await userEvent.click(screen.getByRole('button', { name: /Refresh Agents/ }))
  await userEvent.click(await screen.findByRole('button', { name: /Stun Agent/ }))
  await screen.findByTestId('supercred-stun-event')
  unmount()
}

describe('stun reaches the audit timeline', () => {
  it('shows nothing on the timeline before the stun', async () => {
    render(<MemoryRouter><AuditTrail /></MemoryRouter>)
    await waitFor(() => expect(screen.queryByText('Loading…')).not.toBeInTheDocument())
    expect(within(await auditRows()).queryByText('agent.stunned')).not.toBeInTheDocument()
  })

  it('lands the stun on the Audit Trail with agent, actor and timestamp', async () => {
    await stunViaSuperCredPage()

    render(<MemoryRouter><AuditTrail /></MemoryRouter>)

    const cell = await within(await auditRows()).findByText('agent.stunned')
    const row = cell.closest('tr')
    expect(row).not.toBeNull()
    expect(within(row as HTMLElement).getByText('Cardvault Agent')).toBeInTheDocument()
    // Actor and a rendered timestamp — an event nobody can attribute or place
    // in time is not evidence.
    expect(row?.textContent).toMatch(/demo-operator/)
    expect(row?.textContent).toMatch(/2026/)
  })

  it('records the outcome in the event detail the trail renders', async () => {
    await stunViaSuperCredPage()

    render(<MemoryRouter><AuditTrail /></MemoryRouter>)
    const row = (await within(await auditRows()).findByText('agent.stunned')).closest('tr')
    expect(row?.textContent).toMatch(/"outcome":"stunned"/)
  })

  it('keeps the seeded history alongside the new event', async () => {
    await stunViaSuperCredPage()

    render(<MemoryRouter><AuditTrail /></MemoryRouter>)
    const body = await auditRows()
    await within(body).findByText('agent.stunned')
    expect(within(body).getByText('agent.registered')).toBeInTheDocument()
  })
})
