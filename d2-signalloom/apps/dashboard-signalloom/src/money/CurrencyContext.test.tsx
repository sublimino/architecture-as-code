import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, act } from '@testing-library/react'

// vi.mock is hoisted above every const in this file, so anything a factory
// touches at evaluation time has to be hoisted with it. vi.hoisted is the
// sanctioned way; without it the api factory throws "Cannot access 'getPrefs'
// before initialization" and the whole suite fails to collect.
const { getAccessTokenSilently, auth, getPrefs, patchCurrency } = vi.hoisted(() => {
  const token = vi.fn().mockResolvedValue('test-token')
  return {
    getAccessTokenSilently: token,
    auth: { isAuthenticated: true, getAccessTokenSilently: token },
    getPrefs: vi.fn(),
    patchCurrency: vi.fn(),
  }
})

vi.mock('../auth/oidc', () => ({ useAuth0: () => auth }))
vi.mock('../api/client', () => ({
  api: { userPreferences: { get: getPrefs, patchCurrency } },
}))

import { CurrencyProvider, useMoney, useCurrency } from './CurrencyContext'
import { DEFAULT_CURRENCY } from './currency'
import { resetRateTable, setRateTable } from './rates'
import { convert } from './convert'
import { money } from './money'
import { fakeRateTable } from '../test-utils/rateTable'

beforeEach(() => {
  auth.isAuthenticated = true
  getAccessTokenSilently.mockClear()
  getPrefs.mockReset().mockResolvedValue({ display_currency: 'USD' })
  patchCurrency.mockReset().mockImplementation((_t: string, c: string) => Promise.resolve({ display_currency: c }))
  resetRateTable()
})

/** Renders one converted figure plus the disclosure line. */
function Probe() {
  const { fmtMoney, currency, noteFor } = useMoney()
  // The probe figure is GBP because the demo estate reports GBP; the source
  // currency travels with the value rather than being assumed globally.
  return (
    <div>
      <span data-testid="figure">{fmtMoney({ amount: 1000, currency: 'GBP' }, { locale: 'en-GB' })}</span>
      <span data-testid="currency">{String(currency)}</span>
      <span data-testid="note">{noteFor('GBP') ?? 'none'}</span>
    </div>
  )
}

function Switcher() {
  const { currency, setCurrency, error } = useCurrency()
  return (
    <div>
      <span data-testid="current">{String(currency)}</span>
      <span data-testid="error">{error ?? 'none'}</span>
      <button onClick={() => { void setCurrency('EUR').catch(() => undefined) }}>to EUR</button>
    </div>
  )
}

function renderWith(ui: React.ReactNode) {
  return render(<CurrencyProvider>{ui}</CurrencyProvider>)
}

// Intl is the oracle throughout — see format.test.ts for why a literal would be
// asserting the bug rather than the behaviour.
const intl = (currency: string, value: number) =>
  new Intl.NumberFormat('en-GB', {
    style: 'currency', currency, minimumFractionDigits: 0, maximumFractionDigits: 0,
  }).format(value)

describe('the default is USD', () => {
  it('shows USD for a user who has never chosen', async () => {
    // The server answers with the column DEFAULT for a user with no saved value.
    getPrefs.mockResolvedValue({ display_currency: 'USD' })
    renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('currency')).toHaveTextContent('USD'))
    expect(screen.getByTestId('figure')).toHaveTextContent(intl('USD', convert(money(1000, 'GBP'), 'USD')!.amount))
  })

  it('shows USD for a row that predates the preference column', async () => {
    // Such a row has no value at all for the field. It must not render as a
    // blank, a crash, or the source currency wearing a dollar sign.
    getPrefs.mockResolvedValue({})
    renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('currency')).toHaveTextContent(DEFAULT_CURRENCY))
    expect(screen.getByTestId('figure')).toHaveTextContent(intl('USD', convert(money(1000, 'GBP'), 'USD')!.amount))
  })

  it('falls back to USD rather than trusting a code this build cannot format', async () => {
    // Intl does NOT reject unknown codes — it renders "ZZZ 1,000" — so an
    // unrecognised value from the server has to be caught here or it reaches
    // the screen looking like a real currency.
    getPrefs.mockResolvedValue({ display_currency: 'ZZZ' })
    renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('currency')).toHaveTextContent(DEFAULT_CURRENCY))
    expect(screen.getByTestId('figure')).not.toHaveTextContent('ZZZ')
  })

  it('still renders a working dashboard when the preference cannot be read', async () => {
    getPrefs.mockRejectedValue(new Error('backend down'))
    renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('currency')).toHaveTextContent(DEFAULT_CURRENCY))
  })
})

describe('a saved preference is applied', () => {
  it('renders every figure in the currency the user saved', async () => {
    getPrefs.mockResolvedValue({ display_currency: 'EUR' })
    renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('currency')).toHaveTextContent('EUR'))
    expect(screen.getByTestId('figure')).toHaveTextContent(intl('EUR', convert(money(1000, 'GBP'), 'EUR')!.amount))
  })

  it('survives a reload — the value is read back from the server, not from memory', async () => {
    getPrefs.mockResolvedValue({ display_currency: 'EUR' })
    const first = renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('currency')).toHaveTextContent('EUR'))
    first.unmount()

    // A reload is a fresh mount against the same server state.
    renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('currency')).toHaveTextContent('EUR'))
    expect(getPrefs).toHaveBeenCalledTimes(2)
  })
})

describe('changing the preference', () => {
  it('persists through the per-user endpoint and adopts what the server confirms', async () => {
    renderWith(<Switcher />)
    await waitFor(() => expect(screen.getByTestId('current')).toHaveTextContent('USD'))

    await act(async () => { screen.getByText('to EUR').click() })

    await waitFor(() => expect(screen.getByTestId('current')).toHaveTextContent('EUR'))
    expect(patchCurrency).toHaveBeenCalledWith('test-token', 'EUR')
  })

  it('is scoped by the bearer token alone — no user or tenant id is sent', async () => {
    // Scoping by token is what makes one user's change incapable of moving
    // another's figures. A tenant-scoped call would be a permission check away
    // from doing exactly that.
    renderWith(<Switcher />)
    await waitFor(() => expect(screen.getByTestId('current')).toHaveTextContent('USD'))
    await act(async () => { screen.getByText('to EUR').click() })
    await waitFor(() => expect(patchCurrency).toHaveBeenCalled())

    const args = patchCurrency.mock.calls[0]
    expect(args).toHaveLength(2)
    expect(args[0]).toBe('test-token')
    expect(args[1]).toBe('EUR')
  })

  it('surfaces a failed save instead of showing a currency that was not stored', async () => {
    patchCurrency.mockRejectedValue(new Error('save failed'))
    renderWith(<Switcher />)
    await waitFor(() => expect(screen.getByTestId('current')).toHaveTextContent('USD'))

    await act(async () => { screen.getByText('to EUR').click() })

    await waitFor(() => expect(screen.getByTestId('error')).toHaveTextContent('save failed'))
    // The display must still say USD: the change did not happen.
    expect(screen.getByTestId('current')).toHaveTextContent('USD')
  })
})

describe('an unconvertible figure never renders as though it had been converted', () => {
  it('shows the word Unavailable, with no number and no symbol', async () => {
    // A table with no USD row: the user's currency is USD, the figures are GBP,
    // and there is no rate to bridge them.
    setRateTable(fakeRateTable({ 'GBP->GBP': 1 }, { as_of: '2026-08-01' }))
    getPrefs.mockResolvedValue({ display_currency: 'USD' })

    renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('currency')).toHaveTextContent('USD'))

    const shown = screen.getByTestId('figure').textContent ?? ''
    expect(shown).toBe('Unavailable')
    // The specific failure being guarded: 1000 rendered as "US$1,000", the
    // source number wearing the target currency's symbol, indistinguishable
    // from a real conversion on a slide.
    expect(shown).not.toMatch(/1,?000/)
    expect(shown).not.toMatch(/[$£€]/)
  })
})

describe('the as_of date is visible wherever a converted figure is', () => {
  it('states the rate and its effective date', async () => {
    getPrefs.mockResolvedValue({ display_currency: 'USD' })
    renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('currency')).toHaveTextContent('USD'))
    const note = screen.getByTestId('note').textContent ?? ''
    expect(note).toContain('2026-08-01')
    expect(note).toContain('1.2658')
    expect(note).toContain('GBP')
  })

  it('says nothing when the user is viewing figures in their source currency', async () => {
    getPrefs.mockResolvedValue({ display_currency: 'GBP' })
    renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('currency')).toHaveTextContent('GBP'))
    expect(screen.getByTestId('note')).toHaveTextContent('none')
  })
})

describe('the preference is fetched only when something needs it', () => {
  it('does not call the server for a consumer that shows no money', async () => {
    render(<CurrencyProvider><span data-testid="inert">no money here</span></CurrencyProvider>)
    await waitFor(() => expect(screen.getByTestId('inert')).toBeInTheDocument())
    expect(getPrefs).not.toHaveBeenCalled()
    expect(getAccessTokenSilently).not.toHaveBeenCalled()
  })

  it('does not call the server before there is a signed-in user', async () => {
    auth.isAuthenticated = false
    renderWith(<Probe />)
    await waitFor(() => expect(screen.getByTestId('figure')).toBeInTheDocument())
    expect(getPrefs).not.toHaveBeenCalled()
  })
})
