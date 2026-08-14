// ─── Policy-as-Versioned-Code types ─────────────────────────────────────────
//
// Every money figure here is a `Money`, never a bare number. The currency used
// to be welded into the field NAME — `carriedGbp`, `totalExposureGbp` — which
// meant three things at once, all bad: the currency could not vary, a rename
// could silently redenominate a value, and arithmetic across two currencies
// type-checked cleanly.
//
// It also made the frontend carry a `SOURCE_CURRENCY = 'GBP'` constant that was
// true only by coincidence. `riskctl --json` reports in each ORG's own currency
// (`doc.Currency`), and risk/org/ludlow-health.yaml is a US provider whose
// amounts are all GBP — so the constant was one org file away from silently
// mislabelling every figure on screen. The currency now travels with the data.
//
// Matches the `{amount, currency}` shape the engine emits, which has a
// TestNoBareMoneyCrossesTheWire guard on the Go side.

import type { CurrencyCode } from '../money/currency'
import type { Money } from '../money/money'

export interface ComplianceCheck {
  framework: string
  controlSet: string
  control: string
  check: string
  passed: boolean
  policyVersion: string
  ale: Money
  var95: Money
  tvar: Money
  /** Residual exposure carried by this control when it fails. */
  carried: Money
  scanTimestamp: string
  calibrationSource: string
}

export interface FrameworkSummary {
  id: string
  name: string
  versions: string[]
  totalControls: number
  passedControls: number
  failedControls: number
  totalExposure: Money
}

export interface ComplianceScanRequest {
  namespace: string
  policyVersion: string
  frameworks: string[]
}

export interface PostureSummary {
  totalChecks: number
  passed: number
  failed: number
  /**
   * The reporting currency of this document — the engine's `doc.Currency`.
   *
   * Per-ORG, not global: two institutions in the same product can report in
   * different denominations, so this is read from the payload and never
   * assumed. It is also the fallback currency for an empty sum, where there is
   * no figure to take a currency from.
   */
  currency: CurrencyCode
  totalAle: Money
  totalVar95: Money
  totalTvar: Money
  totalCarried: Money
  scanTimestamp: string
  frameworks: FrameworkSummary[]
}
