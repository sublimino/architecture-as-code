import type { CurrencyCtx } from '../../money/CurrencyContext'

export const FIXTURE_CURRENCY_CONTEXT_VALUE: CurrencyCtx = Object.freeze({
  currency: null,
  setCurrency: async () => undefined,
  loading: false,
  error: null,
  ensureLoaded: () => undefined,
})
