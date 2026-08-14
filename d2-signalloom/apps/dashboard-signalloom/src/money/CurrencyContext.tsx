// Per-user display currency, and the one hook every money surface uses.
//
// ── Why the no-provider default is "source currency" ────────────────────────
// A component rendered outside CurrencyProvider (unit tests, Storybook) has no
// user preference and no business inventing one. It therefore displays each
// figure in the currency that figure is actually denominated in, unconverted.
// That is the only truthful answer available, and it keeps the rendered value
// honest rather than defaulting to USD and silently applying a rate on behalf
// of a user who does not exist.
//
// Note this is NOT the product default. A real user with no saved preference
// gets DEFAULT_CURRENCY (USD) — that decision lives in the provider and in
// migration 020's column DEFAULT, which have to agree.

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { DEFAULT_CURRENCY, isCurrencyCode, type CurrencyCode } from './currency'
import { sourceMoney, type Converted, type Money } from './money'
import { convert } from './convert'
import {
  formatConverted,
  formatConversionNote,
  formatAsOfNote,
  type FormatOptions,
} from './format'

export interface CurrencyCtx {
  /**
   * The user's display currency, or null when no provider is mounted — see the
   * file header for why null means "each figure in its own currency".
   */
  currency: CurrencyCode | null
  /** Persists to the server and audits. Rejects if the save fails. */
  setCurrency: (next: CurrencyCode) => Promise<void>
  /** True while the saved preference is still being fetched. */
  loading: boolean
  /** Last save or load failure, for the Settings surface to show. */
  error: string | null
  /**
   * Declares that this consumer is about to show or edit money, which is what
   * triggers the one fetch of the saved preference.
   *
   * The preference is fetched on demand rather than on mount because most of
   * the dashboard shows no money at all, and an unconditional fetch put a
   * server round trip on the pre-auth and onboarding-gate renders — which
   * onboardingGate.test.tsx exists to forbid, having been written for a
   * routing regression that turned on exactly that kind of unnecessary call.
   */
  ensureLoaded: () => void
}

export const CurrencyContext = createContext<CurrencyCtx>({
  currency: null,
  setCurrency: () => Promise.resolve(),
  loading: false,
  error: null,
  ensureLoaded: () => undefined,
})

export function CurrencyProvider({ children }: { children: ReactNode }) {
  const { getAccessTokenSilently, isAuthenticated } = useAuth0()
  // Optimistic default so the first paint shows the documented default rather
  // than a blank where a number belongs. If the server says otherwise, the
  // effect below corrects it before the user can act on it.
  const [currency, setCurrencyState] = useState<CurrencyCode>(DEFAULT_CURRENCY)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // Flipped by ensureLoaded() when a consumer first needs money. See the
  // CurrencyCtx docs for why the fetch is demand-driven.
  const [demanded, setDemanded] = useState(false)

  const ensureLoaded = useCallback(() => setDemanded(true), [])

  useEffect(() => {
    // A preference belongs to a signed-in user, so there is nobody to fetch one
    // for until there is a session — and nothing to fetch for until something
    // on screen actually shows money.
    if (!isAuthenticated || !demanded) return

    setLoading(true)
    let cancelled = false
    ;(async () => {
      try {
        const token = await getAccessTokenSilently()
        const prefs = await api.userPreferences.get(token)
        if (cancelled) return
        // An unrecognised code from the server is treated as no preference.
        // Rendering figures in a currency this build cannot format correctly
        // would be worse than falling back to the documented default.
        setCurrencyState(isCurrencyCode(prefs.display_currency) ? prefs.display_currency : DEFAULT_CURRENCY)
        setError(null)
      } catch {
        if (cancelled) return
        // A user whose preference cannot be read still gets a working
        // dashboard in the documented default. Their saved choice is not lost;
        // it simply is not applied this session.
        setCurrencyState(DEFAULT_CURRENCY)
        setError(null)
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => { cancelled = true }
  }, [getAccessTokenSilently, isAuthenticated, demanded])

  const setCurrency = useCallback(async (next: CurrencyCode) => {
    const token = await getAccessTokenSilently()
    try {
      const saved = await api.userPreferences.patchCurrency(token, next)
      // Adopt what the server confirms, not what was asked for. If the two ever
      // disagree, the screen agrees with the audit trail rather than with the
      // click that did not take.
      setCurrencyState(isCurrencyCode(saved.display_currency) ? saved.display_currency : next)
      setError(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save your currency preference')
      throw err
    }
  }, [getAccessTokenSilently])

  const value = useMemo<CurrencyCtx>(
    () => ({ currency, setCurrency, loading, error, ensureLoaded }),
    [currency, setCurrency, loading, error, ensureLoaded],
  )

  return <CurrencyContext.Provider value={value}>{children}</CurrencyContext.Provider>
}

export interface MoneyRenderer {
  /** The currency figures are being shown in. */
  currency: CurrencyCode | null
  /**
   * Format a source-currency amount for display.
   *
   * Returns MONEY_UNAVAILABLE when no rate exists. This is the drop-in
   * replacement for the old `fmtGbp(n)` at every call site.
   */
  fmt: (amount: number, options?: FormatOptions) => string
  /** The same, for a value that already knows its own currency. */
  fmtMoney: (m: Money, options?: FormatOptions) => string
  /** The Converted behind a figure, for callers that need the working. */
  convertAmount: (amount: number) => Converted | null
  /**
   * Provenance line for the surface: rate and effective date, or null when
   * nothing was converted and there is therefore nothing to disclose.
   */
  conversionNote: string | null
  /** Short form of the same, for dense surfaces. */
  asOfNote: string | null
}

/**
 * Everything a money surface needs, resolved against the user's preference.
 *
 * Deliberately one hook rather than a formatting util plus a currency lookup:
 * the two must not be able to drift apart, because a figure formatted with one
 * currency and labelled with another is exactly the defect this work exists to
 * prevent.
 */
export function useMoney(): MoneyRenderer {
  const { currency, ensureLoaded } = useContext(CurrencyContext)

  // Mounting a money surface is the signal that the saved preference is now
  // worth fetching.
  useEffect(() => { ensureLoaded() }, [ensureLoaded])

  return useMemo(() => {
    const target = currency
    const convertAmount = (amount: number): Converted | null => {
      const src = sourceMoney(amount)
      // No provider: show the figure in its own currency, unconverted.
      return convert(src, target ?? src.currency)
    }

    // Every figure on a surface shares one source and one target currency, so
    // one probe answers whether a disclosure line is needed at all.
    const probe = convertAmount(0)

    return {
      currency: target,
      fmt: (amount, options) => formatConverted(convertAmount(amount), options),
      fmtMoney: (m, options) => formatConverted(convert(m, target ?? m.currency), options),
      convertAmount,
      conversionNote: formatConversionNote(probe),
      asOfNote: formatAsOfNote(probe),
    }
  }, [currency])
}

/**
 * The setting itself, for the Settings surface. Also declares demand, so
 * opening Settings loads the saved value even though no figure is on screen.
 */
export function useCurrency(): CurrencyCtx {
  const ctx = useContext(CurrencyContext)
  const { ensureLoaded } = ctx
  useEffect(() => { ensureLoaded() }, [ensureLoaded])
  return ctx
}
