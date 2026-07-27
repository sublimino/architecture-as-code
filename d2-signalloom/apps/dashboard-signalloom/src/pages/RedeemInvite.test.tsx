import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import RedeemInvite from './RedeemInvite'

const VALID_CODE = 'SL-ABCD-1234'

function renderWith(code?: string) {
  const search = code !== undefined ? `?code=${encodeURIComponent(code)}` : ''
  return render(
    <MemoryRouter initialEntries={[`/redeem-invite${search}`]}>
      <Routes>
        <Route path="/redeem-invite" element={<RedeemInvite />} />
      </Routes>
    </MemoryRouter>
  )
}

async function fillAndSubmit(orgName = 'Acme Corp', name = 'Jane Smith', email = 'jane@acme.com') {
  await userEvent.type(screen.getByLabelText(/organisation name/i), orgName)
  await userEvent.type(screen.getByLabelText(/your name/i), name)
  await userEvent.type(screen.getByLabelText(/work email/i), email)
  await userEvent.click(screen.getByRole('button', { name: /create workspace/i }))
}

describe('RedeemInvite page', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
  })

  // ---- Code guard: missing code -----------------------------------------------

  it('shows invite-link-required error when no code param is present', () => {
    renderWith()
    expect(screen.getByText(/invite link required/i)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /create workspace/i })).not.toBeInTheDocument()
  })

  // ---- Code guard: malformed code ---------------------------------------------

  it('shows invalid-code error for a completely wrong format', () => {
    renderWith('INVALID')
    expect(screen.getByText(/invalid invite code/i)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /create workspace/i })).not.toBeInTheDocument()
  })

  it('shows invalid-code error for a partial code missing the second segment', () => {
    renderWith('SL-ABCD')
    expect(screen.getByText(/invalid invite code/i)).toBeInTheDocument()
  })

  it('shows invalid-code error for lowercase letters in code', () => {
    renderWith('SL-abcd-1234')
    expect(screen.getByText(/invalid invite code/i)).toBeInTheDocument()
  })

  // ---- Form rendering ---------------------------------------------------------

  it('renders all form fields when code is valid', () => {
    renderWith(VALID_CODE)
    expect(screen.getByLabelText(/organisation name/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/your name/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/work email/i)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /create workspace/i })).toBeInTheDocument()
  })

  it('displays the invite code on the form', () => {
    renderWith(VALID_CODE)
    expect(screen.getByText(VALID_CODE)).toBeInTheDocument()
  })

  it('renders US and EU data region radio buttons with US selected by default', () => {
    renderWith(VALID_CODE)
    const radios = screen.getAllByRole('radio')
    expect(radios).toHaveLength(2)
    const usRadio = radios.find(r => (r as HTMLInputElement).value === 'us')
    expect(usRadio).toBeChecked()
  })

  // ---- Client-side validation -------------------------------------------------

  it('shows error when org name is empty', async () => {
    renderWith(VALID_CODE)
    await userEvent.click(screen.getByRole('button', { name: /create workspace/i }))
    expect(await screen.findByText(/at least 2 characters/i)).toBeInTheDocument()
  })

  it('shows error when admin name is empty', async () => {
    renderWith(VALID_CODE)
    await userEvent.type(screen.getByLabelText(/organisation name/i), 'Acme Corp')
    await userEvent.click(screen.getByRole('button', { name: /create workspace/i }))
    expect(await screen.findByText(/your name is required/i)).toBeInTheDocument()
  })

  it('shows error when email is invalid', async () => {
    renderWith(VALID_CODE)
    await userEvent.type(screen.getByLabelText(/organisation name/i), 'Acme Corp')
    await userEvent.type(screen.getByLabelText(/your name/i), 'Jane')
    await userEvent.type(screen.getByLabelText(/work email/i), 'not-an-email')
    await userEvent.click(screen.getByRole('button', { name: /create workspace/i }))
    expect(await screen.findByText(/valid email/i)).toBeInTheDocument()
  })

  it('does not call fetch when validation fails', async () => {
    const spy = vi.spyOn(globalThis, 'fetch')
    renderWith(VALID_CODE)
    await userEvent.click(screen.getByRole('button', { name: /create workspace/i }))
    expect(spy).not.toHaveBeenCalled()
  })

  // ---- Happy path -------------------------------------------------------------

  it('shows success screen after a 202 response', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: true,
      status: 202,
      json: async () => ({ tenant_id: 'abc-123', next_step: 'check_email' }),
    } as Response)

    renderWith(VALID_CODE)
    await fillAndSubmit()

    expect(await screen.findByText(/check your email/i)).toBeInTheDocument()
    expect(screen.getByText(/jane@acme.com/)).toBeInTheDocument()
  })

  it('includes invite_code in the POST body', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: true,
      status: 202,
      json: async () => ({}),
    } as Response)

    renderWith(VALID_CODE)
    await fillAndSubmit()

    await waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/signup')
    const body = JSON.parse(init.body as string)
    expect(body.invite_code).toBe(VALID_CODE)
    expect(body.org_name).toBe('Acme Corp')
    expect(body.admin_name).toBe('Jane Smith')
    expect(body.admin_email).toBe('jane@acme.com')
  })

  it('disables the submit button while the request is in flight', async () => {
    let resolve!: (v: Response) => void
    vi.spyOn(globalThis, 'fetch').mockImplementationOnce(
      () => new Promise(r => { resolve = r })
    )

    renderWith(VALID_CODE)
    await fillAndSubmit()

    expect(screen.getByRole('button', { name: /creating/i })).toBeDisabled()

    resolve({ ok: true, status: 202, json: async () => ({}) } as Response)
  })

  // ---- Error state: 400 invite_code_invalid -----------------------------------

  it('shows the server message on 400 invite_code_invalid', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: false,
      status: 400,
      json: async () => ({ error: 'invite_code_invalid', message: 'This invite code has expired.' }),
    } as Response)

    renderWith(VALID_CODE)
    await fillAndSubmit()

    expect(await screen.findByText(/expired/i)).toBeInTheDocument()
  })

  it('falls back to default message on 400 with no message field', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: false,
      status: 400,
      json: async () => ({ error: 'invite_code_invalid' }),
    } as Response)

    renderWith(VALID_CODE)
    await fillAndSubmit()

    expect(await screen.findByText(/invalid or has already been used/i)).toBeInTheDocument()
  })

  // ---- Error state: 429 rate_limited ------------------------------------------

  it('shows human-readable retry time on 429 (900 s = 15 minutes)', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: false,
      status: 429,
      json: async () => ({ error: 'rate_limited', retry_after_seconds: 900 }),
    } as Response)

    renderWith(VALID_CODE)
    await fillAndSubmit()

    expect(await screen.findByText(/please try again in 15 minutes/i)).toBeInTheDocument()
  })

  it('shows fallback rate-limit message when retry_after_seconds is absent', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: false,
      status: 429,
      json: async () => ({ error: 'rate_limited' }),
    } as Response)

    renderWith(VALID_CODE)
    await fillAndSubmit()

    expect(await screen.findByText(/rate limited/i)).toBeInTheDocument()
  })

  // ---- Error state: 5xx / network failure -------------------------------------

  it('shows the server message on 500', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: false,
      status: 500,
      json: async () => ({ error: 'provisioning_failed', message: 'Tenant provisioning failed.' }),
    } as Response)

    renderWith(VALID_CODE)
    await fillAndSubmit()

    expect(await screen.findByText(/provisioning failed/i)).toBeInTheDocument()
  })

  it('shows generic error on 5xx with no message field', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce({
      ok: false,
      status: 502,
      json: async () => ({}),
    } as Response)

    renderWith(VALID_CODE)
    await fillAndSubmit()

    expect(await screen.findByText(/something went wrong/i)).toBeInTheDocument()
  })

  it('shows network error when fetch throws', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValueOnce(new Error('Network failure'))

    renderWith(VALID_CODE)
    await fillAndSubmit()

    expect(await screen.findByText(/network error/i)).toBeInTheDocument()
  })
})
