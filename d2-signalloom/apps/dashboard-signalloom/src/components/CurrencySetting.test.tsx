import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const { auth, getPrefs, patchCurrency } = vi.hoisted(() => ({
  auth: { isAuthenticated: true, getAccessTokenSilently: vi.fn().mockResolvedValue('test-token') },
  getPrefs: vi.fn(),
  patchCurrency: vi.fn(),
}))

vi.mock('../auth/oidc', () => ({ useAuth0: () => auth }))
vi.mock('../api/client', () => ({
  api: { userPreferences: { get: getPrefs, patchCurrency } },
}))

import CurrencySetting from './CurrencySetting'
import { CurrencyProvider } from '../money/CurrencyContext'
import { DEFAULT_RATE_TABLE, resetRateTable, setRateTable } from '../money/rates'
import { convert } from '../money/convert'
import { money } from '../money/money'
import { fakeRateTable } from '../test-utils/rateTable'

beforeEach(() => {
  auth.isAuthenticated = true
  resetRateTable()
  getPrefs.mockReset().mockResolvedValue({ display_currency: 'USD' })
  patchCurrency.mockReset().mockImplementation((_t: string, c: string) => Promise.resolve({ display_currency: c }))
})

function renderSetting() {
  return render(<CurrencyProvider><CurrencySetting /></CurrencyProvider>)
}

describe('the currency control', () => {
  it('offers the supported currencies and starts on the saved one', async () => {
    getPrefs.mockResolvedValue({ display_currency: 'EUR' })
    renderSetting()

    const select = await screen.findByTestId('settings-currency')
    await waitFor(() => expect(select).toHaveValue('EUR'))
    expect(screen.getByRole('option', { name: /USD/ })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: /GBP/ })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: /EUR/ })).toBeInTheDocument()
  })

  it('defaults to USD for a user who has never chosen', async () => {
    getPrefs.mockResolvedValue({})
    renderSetting()
    await waitFor(() => expect(screen.getByTestId('settings-currency')).toHaveValue('USD'))
  })

  it('saves the choice through the per-user endpoint', async () => {
    const user = userEvent.setup()
    renderSetting()
    await waitFor(() => expect(screen.getByTestId('settings-currency')).toHaveValue('USD'))

    await user.selectOptions(screen.getByTestId('settings-currency'), 'EUR')

    await waitFor(() => expect(patchCurrency).toHaveBeenCalledWith('test-token', 'EUR'))
    await waitFor(() => expect(screen.getByTestId('settings-currency')).toHaveValue('EUR'))
  })

  it('previews the format with the same formatter the risk pages use', async () => {
    renderSetting()
    const preview = await screen.findByTestId('settings-currency-preview')
    await waitFor(() => {
      // 1,284,000 GBP at the checked-in rate, formatted by Intl rather than by
      // a symbol this component pastes on the front.
      // pairs.GBP.USD via convert(), not rates.USD — under a USD-based table
      // rates.USD is 1, and reaching for it is the reciprocal trap.
      const expected = new Intl.NumberFormat('en-US', {
        style: 'currency', currency: 'USD', minimumFractionDigits: 0, maximumFractionDigits: 0,
      }).format(convert(money(1_284_000, 'GBP'), 'USD', DEFAULT_RATE_TABLE)!.amount)
      expect(preview).toHaveTextContent(expected)
    })
  })

  it('shows the rate and its effective date where the choice is made', async () => {
    renderSetting()
    const rate = await screen.findByTestId('settings-currency-rate')
    expect(rate).toHaveTextContent(DEFAULT_RATE_TABLE.as_of)
    expect(rate).toHaveTextContent('1.2658')
  })

  it('hides the rate line when the user views figures in the source currency', async () => {
    getPrefs.mockResolvedValue({ display_currency: 'GBP' })
    renderSetting()
    await waitFor(() => expect(screen.getByTestId('settings-currency')).toHaveValue('GBP'))
    expect(screen.queryByTestId('settings-currency-rate')).not.toBeInTheDocument()
  })

  it('reports a failed save rather than showing a choice that was not stored', async () => {
    const user = userEvent.setup()
    patchCurrency.mockRejectedValue(new Error('backend refused'))
    renderSetting()
    await waitFor(() => expect(screen.getByTestId('settings-currency')).toHaveValue('USD'))

    await user.selectOptions(screen.getByTestId('settings-currency'), 'EUR')

    await waitFor(() => expect(screen.getByTestId('settings-currency-error')).toHaveTextContent('backend refused'))
    // Still USD: the control must not advertise a preference the server rejected.
    expect(screen.getByTestId('settings-currency')).toHaveValue('USD')
  })

  it('previews Unavailable when the chosen currency cannot be converted to', async () => {
    setRateTable(fakeRateTable({ 'GBP->GBP': 1 }, { as_of: '2026-08-01' }))
    renderSetting()
    const preview = await screen.findByTestId('settings-currency-preview')
    await waitFor(() => expect(preview).toHaveTextContent('Unavailable'))
    expect(preview.textContent).not.toMatch(/[$€]/)
  })

  // The two misreadings this control invites: that changing it restates the
  // underlying risk data, and that the figures are converted at a live rate.
  // Both are answered on the control rather than in a document.
  it('says it changes presentation only, and that the rates ship with the release', async () => {
    const user = userEvent.setup()
    renderSetting()

    await user.hover(await screen.findByTestId('settings-currency-help'))

    const tip = await screen.findByRole('tooltip')
    expect(tip.textContent).toContain('underlying risk data is unchanged')
    expect(tip.textContent).toContain('rate table shipped with this release')
  })
})
