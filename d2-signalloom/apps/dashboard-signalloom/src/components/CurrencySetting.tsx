// The per-user display currency control.
//
// Deliberately its own card rather than a third field inside Display. Load
// Times next door is a browser-local preference that applies instantly and is
// remembered on this browser only; this one is saved server-side against the
// signed-in user, is audited, and follows them to another machine. Sitting the
// two under one heading would imply the same durability for both, and the one
// that is merely local is the one people would assume travels.

import { useCallback, useState } from 'react'
import HelpHint from './HelpHint'
import { useCurrency, useMoney } from '../money/CurrencyContext'
import { CURRENCY_LABELS, SUPPORTED_CURRENCIES, isCurrencyCode, type CurrencyCode } from '../money/currency'

/** The figure used to preview the chosen format. Arbitrary but memorable. */
const PREVIEW_AMOUNT = 1_284_000

/**
 * The currency the preview figure is quoted in.
 *
 * The demo estate reports in GBP, so previewing from GBP shows the conversion
 * the user will actually see. Named here rather than assumed globally: the
 * reporting currency is per-org and travels with each payload.
 */
const PREVIEW_SOURCE: CurrencyCode = 'GBP'

export default function CurrencySetting() {
  const { currency, setCurrency, loading, error } = useCurrency()
  const { fmtMoney, noteFor } = useMoney()
  const [saving, setSaving] = useState(false)

  const onChange = useCallback(
    async (next: string) => {
      if (!isCurrencyCode(next)) return
      setSaving(true)
      try {
        await setCurrency(next)
      } catch {
        // The provider has already recorded the message in `error`; this catch
        // exists so a rejected save does not surface as an unhandled rejection.
      } finally {
        setSaving(false)
      }
    },
    [setCurrency],
  )

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
      <div>
        <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 6 }}>
          Display Currency
          <HelpHint label="What Display Currency changes" testId="settings-currency-help">
            Changes only how figures are shown to you. The underlying risk data is unchanged,
            and this setting is saved against your account rather than your team&apos;s. Figures
            are converted using a rate table shipped with this release, so the date beside a
            converted figure tells you which rates produced it.
          </HelpHint>
        </div>
        <select
          data-testid="settings-currency"
          aria-label="Display currency"
          value={currency ?? ''}
          disabled={loading || saving}
          onChange={(e) => { void onChange(e.target.value) }}
          style={{ width: '100%' }}
        >
          {SUPPORTED_CURRENCIES.map((code) => (
            <option key={code} value={code}>{code} — {CURRENCY_LABELS[code]}</option>
          ))}
        </select>

        {/* A worked example beats a description of one. The preview is produced
            by the same formatter the risk pages use, so what is shown here is
            what will be shown there — including whether the figure could be
            converted at all. */}
        <p data-testid="settings-currency-preview" style={{ fontSize: 11, color: 'var(--muted)', marginTop: 8, marginBottom: 0 }}>
          Figures will look like <span style={{ fontWeight: 600, color: 'var(--text)' }}>{fmtMoney({ amount: PREVIEW_AMOUNT, currency: PREVIEW_SOURCE })}</span>
        </p>

        {error !== null && (
          <p data-testid="settings-currency-error" style={{ fontSize: 11, color: 'var(--error)', marginTop: 8, marginBottom: 0 }}>
            {error}
          </p>
        )}
      </div>

      <div>
        <p style={{ fontSize: 11, color: 'var(--muted)', marginTop: 24 }}>
          Applies to every risk and exposure figure in the dashboard. Saved against your account,
          not your team&apos;s — changing it here does not move anyone else&apos;s numbers.
        </p>
        {/* The rate and its effective date, on the surface where the choice is
            made. A converted figure whose date the user has never been shown is
            one they cannot defend when asked where it came from. */}
        {noteFor(PREVIEW_SOURCE) !== null && (
          <p data-testid="settings-currency-rate" style={{ fontSize: 11, color: 'var(--muted)', marginTop: 8 }}>
            {noteFor(PREVIEW_SOURCE)}
          </p>
        )}
        <p style={{ fontSize: 11, color: 'var(--muted)', marginTop: 8 }}>
          Rates come from a table checked in with the code, so a figure can always be traced back to
          the exact rate that produced it. They are not live market rates.
        </p>
      </div>
    </div>
  )
}
