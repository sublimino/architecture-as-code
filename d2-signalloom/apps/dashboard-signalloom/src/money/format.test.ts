import { describe, it, expect, afterEach, vi } from 'vitest'
import {
  formatAmount,
  formatMoney,
  formatConverted,
  formatConversionNote,
  formatAsOfNote,
  resolveLocale,
  MONEY_UNAVAILABLE,
  FALLBACK_LOCALE,
  COMPACT_THRESHOLD,
} from './format'
import { money } from './money'
import { convert } from './convert'
import { resetRateTable, setRateTable } from './rates'
import { fakeRateTable } from '../test-utils/rateTable'

afterEach(() => {
  resetRateTable()
  vi.unstubAllGlobals()
})

// Every expectation below is computed from Intl rather than written as a
// literal. A hardcoded "$1,266" would be wrong in two separate ways at once —
// en-GB renders US dollars as "US$", and the grouping separator is locale
// dependent — and the test would then be asserting the bug.
function intl(locale: string, currency: string, value: number, opts: Intl.NumberFormatOptions = {}) {
  return new Intl.NumberFormat(locale, {
    style: 'currency',
    currency,
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
    ...opts,
  }).format(value)
}

describe('formatAmount — symbol, placement and grouping come from Intl', () => {
  it('renders USD for a UK locale the way Intl does, disambiguated as US$', () => {
    const out = formatAmount(1266, 'USD', { locale: 'en-GB' })
    expect(out).toBe(intl('en-GB', 'USD', 1266))
    // Pin the property that matters rather than the whole string: a UK reader
    // must not be shown a bare "$" that could equally be CAD or AUD.
    expect(out).toContain('US$')
  })

  it('renders GBP with a leading pound and comma grouping for en-GB', () => {
    const out = formatAmount(847000, 'GBP', { locale: 'en-GB' })
    expect(out).toBe(intl('en-GB', 'GBP', 847000))
    expect(out).toContain('847,000')
  })

  it('places the symbol AFTER the number for a locale that does so', () => {
    // de-DE renders "1.234.568 €". Any implementation that concatenates a
    // symbol onto the front passes every en-GB test and fails this one.
    const out = formatAmount(1234568, 'EUR', { locale: 'de-DE' })
    expect(out).toBe(intl('de-DE', 'EUR', 1234568))
    expect(out.trimEnd().endsWith('€')).toBe(true)
    expect(out.startsWith('€')).toBe(false)
  })

  it('uses the locale grouping separator, not a hardcoded comma', () => {
    const out = formatAmount(1234568, 'EUR', { locale: 'de-DE' })
    expect(out).toContain('1.234.568')
  })

  it('shows whole units — no stray cents on a risk aggregate', () => {
    const out = formatAmount(1265.8, 'USD', { locale: 'en-GB' })
    expect(out).toBe(intl('en-GB', 'USD', 1265.8))
    expect(out).not.toContain('.80')
  })
})

describe('formatAmount — compact notation', () => {
  // The abbreviation suffix is a CLDR fact, not an English one: en-GB writes
  // "£2.5m" in lowercase while en-US writes "$2.5M", and de-DE writes "Mio.".
  // Asserting on an uppercase "M" would pin one locale's spelling and quietly
  // fail on an ICU upgrade, so these check the PROPERTY — that the output is
  // the abbreviated form and is shorter than the grouped one.
  it('abbreviates at or above the threshold', () => {
    const out = formatAmount(2_500_000, 'GBP', { locale: 'en-GB', compact: true })
    expect(out).toBe(intl('en-GB', 'GBP', 2_500_000, { notation: 'compact', maximumFractionDigits: 1 }))
    expect(out).toMatch(/2[.,]5/)
    expect(out.length).toBeLessThan(intl('en-GB', 'GBP', 2_500_000).length)
  })

  it('groups in full below the threshold, preserving the pre-existing look', () => {
    const out = formatAmount(847_000, 'GBP', { locale: 'en-GB', compact: true })
    // The behaviour FleetRiskGauge already had: only millions abbreviate.
    expect(out).toBe(intl('en-GB', 'GBP', 847_000))
    expect(out).toContain('847,000')
  })

  it('treats the threshold itself as compact', () => {
    const out = formatAmount(COMPACT_THRESHOLD, 'GBP', { locale: 'en-GB', compact: true })
    expect(out).toBe(intl('en-GB', 'GBP', COMPACT_THRESHOLD, { notation: 'compact', maximumFractionDigits: 1 }))
    expect(out.length).toBeLessThan(intl('en-GB', 'GBP', COMPACT_THRESHOLD).length)
  })

  it('abbreviates USD compactly with the US$ marker intact', () => {
    const out = formatAmount(3_164_500, 'USD', { locale: 'en-GB', compact: true })
    expect(out).toBe(intl('en-GB', 'USD', 3_164_500, { notation: 'compact', maximumFractionDigits: 1 }))
  })
})

describe('formatMoney', () => {
  it('formats in the money value own currency without implying conversion', () => {
    expect(formatMoney(money(1000, 'GBP'), { locale: 'en-GB' })).toBe(intl('en-GB', 'GBP', 1000))
  })
})

describe('formatConverted — an unconvertible figure never wears the target symbol', () => {
  it('formats a successful conversion in the target currency', () => {
    const c = convert(money(1000, 'GBP'), 'USD')
    expect(c).not.toBeNull()
    expect(formatConverted(c, { locale: 'en-GB' })).toBe(intl('en-GB', 'USD', c!.amount))
  })

  it('renders the word Unavailable when there is no rate', () => {
    // The canonical table answers every pair, so an unconvertible figure needs
    // a table that genuinely cannot answer — which is what a partial or failed
    // rate load would look like in production.
    setRateTable(fakeRateTable({ 'GBP->GBP': 1 }))
    const c = convert(money(1000, 'GBP'), 'USD')
    expect(c).toBeNull()
    expect(formatConverted(c, { locale: 'en-GB' })).toBe(MONEY_UNAVAILABLE)
  })

  it('shows no currency symbol at all when unavailable', () => {
    const out = formatConverted(null)
    // The failure this guards is the one that puts a wrong figure on a slide:
    // the source number rendered with the target currency's symbol, looking
    // for all the world like it had been converted.
    expect(out).not.toMatch(/[$£€]/)
    expect(out).not.toMatch(/\d/)
  })

  it('is not a dash — a dash reads as zero, and zero exposure is a claim', () => {
    expect(formatConverted(null)).not.toBe('—')
    expect(formatConverted(null)).not.toBe('-')
  })
})

describe('conversion provenance is visible', () => {
  it('states the rate and the as_of date for a real conversion', () => {
    const c = convert(money(1000, 'GBP'), 'USD')
    const note = formatConversionNote(c)
    expect(note).toContain('GBP')
    expect(note).toContain('1.2658')
    expect(note).toContain('2026-08-01')
  })

  it('offers a short as_of suffix for dense surfaces', () => {
    const c = convert(money(1000, 'GBP'), 'USD')
    expect(formatAsOfNote(c)).toContain('2026-08-01')
  })

  it('stays silent when nothing was converted', () => {
    // GBP shown as GBP is not a conversion. A "converted at 1.0" line here
    // would train readers to ignore the line on the rows that matter.
    const c = convert(money(1000, 'GBP'), 'GBP')
    expect(formatConversionNote(c)).toBeNull()
    expect(formatAsOfNote(c)).toBeNull()
  })

  it('has no note to show when the figure is unavailable', () => {
    expect(formatConversionNote(null)).toBeNull()
    expect(formatAsOfNote(null)).toBeNull()
  })

  it('reports the as_of of whichever table is installed', () => {
    setRateTable(fakeRateTable({ 'GBP->GBP': 1, 'GBP->USD': 1.4 }, { as_of: '2027-01-15' }))
    const c = convert(money(100, 'GBP'), 'USD')
    expect(formatAsOfNote(c)).toContain('2027-01-15')
  })
})

describe('resolveLocale', () => {
  it('keys off the browser language when present', () => {
    vi.stubGlobal('navigator', { language: 'de-DE' })
    expect(resolveLocale()).toBe('de-DE')
  })

  it('falls back to en-GB when the browser will not say', () => {
    vi.stubGlobal('navigator', { language: '' })
    expect(resolveLocale()).toBe(FALLBACK_LOCALE)
  })
})
