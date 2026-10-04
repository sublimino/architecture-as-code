import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import RedeemInvite, { messageFor } from './RedeemInvite'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently: async () => 'dex-id-token' }),
}))

const TOKEN = 'k7Qp2mZ8vX1nR4tL9wB3yC6dF0hJ5sA2eG8uM1oP4iK'

function renderWith(query = '') {
  return render(
    <MemoryRouter initialEntries={[`/redeem-invite${query}`]}>
      <Routes>
        <Route path="/redeem-invite" element={<RedeemInvite />} />
      </Routes>
    </MemoryRouter>,
  )
}

function mockFetch(status: number, body: unknown) {
  const fetchMock = vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  })
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

const BOUND = { subject: 'carol', tenant: 'kusari', bound_via: 'invite', bound_at: '2026-10-04T10:00:00Z', email: 'carol@kusari.dev' }

describe('RedeemInvite page', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('prefills the token from ?token= and keeps ?code= working for older links', () => {
    renderWith(`?token=${TOKEN}`)
    expect(screen.getByLabelText(/invite token/i)).toHaveValue(TOKEN)
    expect(screen.getByText(/the token from your link is filled in/i)).toBeInTheDocument()
  })

  it('accepts the legacy ?code= parameter', () => {
    renderWith(`?code=${TOKEN}`)
    expect(screen.getByLabelText(/invite token/i)).toHaveValue(TOKEN)
  })

  it('renders an empty form, not an error, when the link carries no token', () => {
    renderWith()
    expect(screen.getByLabelText(/invite token/i)).toHaveValue('')
    expect(screen.getByRole('button', { name: /redeem invite/i })).toBeEnabled()
  })

  it('refuses to call the API with a token that is too short', async () => {
    const fetchMock = mockFetch(200, BOUND)
    renderWith()
    await userEvent.type(screen.getByLabelText(/invite token/i), 'short')
    await userEvent.click(screen.getByRole('button', { name: /redeem invite/i }))
    expect(await screen.findByRole('alert')).toHaveTextContent(/full invite token/i)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('posts the token with the Dex bearer to /api/v1/invites/redeem and shows the bound tenant', async () => {
    const fetchMock = mockFetch(200, BOUND)
    renderWith(`?token=${TOKEN}`)
    await userEvent.click(screen.getByRole('button', { name: /redeem invite/i }))

    expect(await screen.findByTestId('redeem-success')).toBeInTheDocument()
    expect(screen.getByTestId('bound-tenant')).toHaveTextContent('kusari')
    expect(screen.getByText('carol@kusari.dev')).toBeInTheDocument()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/invites/redeem')
    expect(init.method).toBe('POST')
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer dex-id-token')
    expect(JSON.parse(init.body as string)).toEqual({ token: TOKEN })
  })

  it('disables the button while the request is in flight', async () => {
    let resolve: (v: unknown) => void = () => {}
    vi.stubGlobal('fetch', vi.fn().mockReturnValue(new Promise(r => { resolve = r })))
    renderWith(`?token=${TOKEN}`)
    await userEvent.click(screen.getByRole('button', { name: /redeem invite/i }))
    expect(screen.getByRole('button', { name: /redeeming/i })).toBeDisabled()
    resolve({ ok: true, status: 200, json: async () => BOUND })
    await waitFor(() => expect(screen.getByTestId('redeem-success')).toBeInTheDocument())
  })

  it.each([
    [404, {}, /no invite matches/i],
    [410, { error: { code: 'invite_expired' } }, /has expired/i],
    [410, { error: { code: 'invite_redeemed' } }, /already been redeemed/i],
    [409, { error: { code: 'tenant_mismatch', message: "Subject is already bound to tenant 'tenant-a'; this invite is for 'kusari'" } }, /already bound to tenant 'tenant-a'/i],
    [403, { error: { code: 'invite_email_mismatch' } }, /different email address/i],
    [503, { error: { code: 'database_unavailable' } }, /cannot reach its database/i],
    [401, {}, /session has expired/i],
  ])('explains a %s refusal and stays on the form', async (status, body, expected) => {
    mockFetch(status, body)
    renderWith(`?token=${TOKEN}`)
    await userEvent.click(screen.getByRole('button', { name: /redeem invite/i }))
    expect(await screen.findByRole('alert')).toHaveTextContent(expected)
    expect(screen.queryByTestId('redeem-success')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: /redeem invite/i })).toBeEnabled()
  })

  it('reports a network failure without pretending the binding happened', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')))
    renderWith(`?token=${TOKEN}`)
    await userEvent.click(screen.getByRole('button', { name: /redeem invite/i }))
    expect(await screen.findByRole('alert')).toHaveTextContent(/network error/i)
  })

  it('prefers the server message for an unmapped status', () => {
    expect(messageFor(500, { error: { message: 'boom' } })).toBe('boom')
    expect(messageFor(500, {})).toMatch(/something went wrong/i)
  })
})
