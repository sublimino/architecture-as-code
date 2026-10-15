// ─── Policy-as-Versioned-Code types ─────────────────────────────────────────
//
// Every money figure here is a `Money`, never a bare number. The currency used
// to be welded into the field NAME: `carriedGbp`, `totalExposureGbp`, which
// meant three things at once, all bad: the currency could not vary, a rename
// could silently redenominate a value, and arithmetic across two currencies
// type-checked cleanly.
//
// It also made the frontend carry a `SOURCE_CURRENCY = 'GBP'` constant that was
// true only by coincidence. `riskctl --json` reports in each ORG's own currency
// (`doc.Currency`), and risk/org/ludlow-health.yaml is a US provider whose
// amounts are all GBP, so the constant was one org file away from silently
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
  currency?: CurrencyCode
  ale: Money
  var95: Money
  tvar: Money
  /** Residual exposure carried by this control when it fails. */
  carried: Money
  scanTimestamp: string
  calibrationSource: string
}

/**
 * Why a route reported no money figure.
 *
 * The same object policy-engine and fe-signalloom both send, every key always
 * present. `status` is the only field to branch on -- `available` is derived
 * from it server-side and reading both can only ever write a disagreement the
 * server cannot produce. See api/fleetApi.ts for the canonical commentary.
 *
 * On the policy summary response this appears at TWO levels: once for the
 * headline figures and once inside each `frameworks` entry. Both say the same
 * thing there, and that is correct -- the cause is the same -- so read the
 * outer one for the headline and the inner one per row.
 */
export interface PricingRefusal {
  available: boolean
  status: 'PRICED' | 'NO_DECLARED_LOSS_FREQUENCY' | 'NO_RISK_DATA_PLANE' | string
  reason: string
  unpricedFields: string[]
  unmappedChecks: string[]
}

export interface FrameworkSummary {
  id: string
  name: string
  versions: string[]
  totalControls: number
  passedControls: number
  failedControls: number
  /**
   * `null` when this route could not price its own findings.
   *
   * GET /compliance/policy/frameworks answers from `agent_compliance_results`,
   * which has no money column (migration 004), so there is nothing to
   * aggregate and it now reports null rather than a hardcoded 0. Nullable here
   * so the compiler forces each reader to distinguish "not computed" from
   * "computed as zero" -- they are different claims and only one is a figure.
   */
  totalExposure: Money | null
  /** Denominated twin returned by backend API (/compliance/policy/frameworks) */
  exposure?: Money | null
  totalExposureGbp?: number | null
  /** This framework row's own refusal. Same cause as the outer one. */
  pricing?: PricingRefusal
}

export interface ComplianceScanRequest {
  namespace: string
  policyVersion: string
  frameworks: string[]
  agentIds?: string[]
}

export interface ComplianceScanResponse {
  checks: ComplianceCheck[]
  summary: PostureSummary
  engineInvoked?: boolean
  agentsScanned?: number
  agentsFailed?: string[]
  agentsNotFound?: string[]
  controlGaps?: unknown[]
}

export interface PostureSummary {
  totalChecks: number
  passed: number
  failed: number
  /**
   * The reporting currency of this document: the engine's `doc.Currency`.
   *
   * Per-ORG, not global: two institutions in the same product can report in
   * different denominations, so this is read from the payload and never
   * assumed. It is also the fallback currency for an empty sum, where there is
   * no figure to take a currency from.
   */
  currency: CurrencyCode
  /**
   * The four aggregate money figures, or `null` on a route that cannot
   * compute them.
   *
   * GET /compliance/policy/summary used to hardcode all four to 0 and emit a
   * denominated `{amount: 0}` beside each. The zeros were never computed and
   * cannot be: the route answers from `agent_compliance_results`, which has no
   * money column. A comment said the zero meant "no exposure value available",
   * but a comment is not on the wire -- a consumer receives an int it can add,
   * chart and quote, and a total exposure of 0 reads as a clean posture.
   *
   * They are null now, which is not addable and cannot render as a currency
   * amount, so absence survives serialisation. Nullable HERE because the
   * client's own normaliser was converting that null straight back into
   * `{ amount: 0, currency }` before any page saw it, which silently undid the
   * whole server-side change.
   */
  totalAle: Money | null
  totalVar95: Money | null
  totalTvar: Money | null
  totalCarried: Money | null
  /** Denominated twin returned by backend API (/compliance/policy/summary) */
  carried?: Money | null
  totalCarriedGbp?: number | null
  scanTimestamp: string
  frameworks: FrameworkSummary[]
  /** Why there is no figure, when there is none. Read this one for the headline. */
  pricing?: PricingRefusal
}
