/**
 * Quantitative risk, priced.
 *
 * Renders the four OpenFAIR figures the Phase 2 work decomposition names — LEF,
 * LM, PML, ALE — for one agent or for the fleet, from whichever data plane the
 * DemoToggle currently selects.
 *
 * ─── Provenance is part of the number ──────────────────────────────────────
 *
 * The badge is not decoration. The defect this replaces is a dashboard showing
 * invented risk figures, and a figure whose origin the reader cannot see is
 * indistinguishable from an invented one no matter how it was computed. So the
 * source rides with the value, every time, in both modes.
 *
 * ─── Why big numbers abbreviate ────────────────────────────────────────────
 *
 * TVaR on a caged agent runs to seven figures, and `£1,234,567.89` in a
 * four-across grid cell either wraps to three lines or clips. `formatMoney`'s
 * compact mode is the codebase's existing answer (chart axes already use it),
 * so the figure abbreviates and the full value goes in `title` + the accessible
 * name — abbreviating for the eye must not abbreviate for a screen reader.
 */
import type { ReactNode } from 'react'
import ErrorState from './ErrorState'
import { formatMoney, COMPACT_THRESHOLD } from '../money/format'
import type { Money } from '../money/money'
import type { FairSource, FairTriple } from '../types/fair'

// ─── Frequency formatting ───────────────────────────────────────────────────

/**
 * LEF is events per year and is NOT money, so it never goes through
 * formatMoney. Sub-unit frequencies are the normal case (0.05 events/year is a
 * once-in-twenty-years loss), which is why this keeps two significant figures
 * below 1 rather than rounding a real risk to "0".
 */
export function formatFrequency(n: number): string {
  if (!Number.isFinite(n)) return '—'
  if (n === 0) return '0'
  if (n >= 10) return n.toFixed(0)
  if (n >= 1) return n.toFixed(1)
  return n.toPrecision(2).replace(/0+$/, '').replace(/\.$/, '')
}

/** "0.01 – 0.2 /yr (mode 0.05)" — the whole triple, because a mode alone hides the spread. */
export function formatTriple(t: FairTriple): string {
  return `${formatFrequency(t.min)} – ${formatFrequency(t.max)} /yr (mode ${formatFrequency(t.mode)})`
}

// ─── Presentation ───────────────────────────────────────────────────────────

interface MetricProps {
  testId: string
  label: string
  /** Short form for the cell. */
  display: string
  /** Unabbreviated form for the tooltip and the accessible name. */
  full: string
  hint: string
}

/**
 * One figure.
 *
 * `role="group"` with an `aria-label` carrying the FULL value, because the
 * visible text may be abbreviated and a screen reader announcing "£773.0k" when
 * the figure is £772,681.87 is a worse outcome than no abbreviation at all.
 */
function Metric({ testId, label, display, full, hint }: MetricProps) {
  return (
    <div
      role="group"
      aria-label={`${label}: ${full}. ${hint}`}
      data-testid={testId}
      style={{
        minWidth: 0,
        padding: '10px 12px',
        borderRadius: 8,
        border: '1px solid var(--border)',
        background: 'var(--surface2)',
      }}
    >
      <div style={{ fontSize: 11, color: 'var(--muted)', letterSpacing: 0.3 }}>{label}</div>
      <div
        title={full}
        data-testid={`${testId}-value`}
        style={{
          marginTop: 2,
          fontWeight: 700,
          fontSize: 16,
          color: 'var(--text)',
          // The three properties that make a long figure shrink rather than
          // escape its cell. minWidth:0 on the parent is what lets them work
          // inside a CSS grid track.
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: 'nowrap',
        }}
      >
        {display}
      </div>
    </div>
  )
}

/** The badge that says where every figure above it came from. */
export function SourceBadge({ source, testId }: { source: FairSource; testId: string }) {
  const live = source === 'riskctl'
  return (
    <span
      data-testid={testId}
      aria-label={
        live
          ? 'Data source: live riskctl computation'
          : 'Data source: offline demo fixture, not a live computation'
      }
      style={{
        fontSize: 10,
        fontWeight: 700,
        letterSpacing: 0.4,
        padding: '2px 7px',
        borderRadius: 999,
        border: `1px solid ${live ? 'var(--teal)' : 'var(--amber)'}`,
        color: 'var(--text)',
        whiteSpace: 'nowrap',
      }}
    >
      {live ? 'LIVE riskctl' : 'DEMO fixture'}
    </span>
  )
}

export interface RiskWidgetProps {
  title: string
  /** Loss Event Frequency triple, events/year. Null while loading or errored. */
  lef: FairTriple | null
  /** Loss Magnitude — the modal per-event loss. */
  lossMagnitude: Money | null
  /** Probable Maximum Loss (this engine: the 95th-percentile bad year). */
  pml: Money | null
  /** Annualised Loss Expectancy. */
  ale: Money | null
  /** Mean loss beyond PML. Optional — shown when the caller has it. */
  tvar?: Money | null
  source: FairSource
  loading?: boolean
  error?: string | null
  onRetry?: () => void
  /** Prefix for every test id this widget emits, so two instances never collide. */
  testId?: string
  /** Pinned by tests for deterministic grouping separators. */
  locale?: string
  footer?: ReactNode
}

export default function RiskWidget({
  title,
  lef,
  lossMagnitude,
  pml,
  ale,
  tvar,
  source,
  loading = false,
  error = null,
  onRetry,
  testId = 'risk-widget',
  locale,
  footer,
}: RiskWidgetProps) {
  // Error first. An error with stale data still in state must not render the
  // stale figures under a live badge — that is the "fabricated figure" outcome
  // in its most convincing disguise.
  if (error) {
    return (
      <div className="card" data-testid={`${testId}-error`} style={{ padding: 14 }}>
        <Header title={title} source={source} testId={testId} />
        <ErrorState message={error} onRetry={onRetry} />
      </div>
    )
  }

  const compact = { locale, compact: true, compactThreshold: COMPACT_THRESHOLD }
  const exact = { locale, compact: false }
  const money = (m: Money | null | undefined) => ({
    display: loading ? '…' : formatMoney(m ?? null, compact),
    full: loading ? 'loading' : formatMoney(m ?? null, exact),
  })

  const lm = money(lossMagnitude)
  const pmlF = money(pml)
  const aleF = money(ale)
  const tvarF = money(tvar)

  return (
    <div
      className="card"
      data-testid={testId}
      data-source={source}
      data-loading={loading ? 'true' : 'false'}
      style={{ padding: 14 }}
    >
      <Header title={title} source={source} testId={testId} />
      <div
        role="list"
        aria-label={`${title} OpenFAIR metrics`}
        style={{
          marginTop: 10,
          display: 'grid',
          // auto-fit + minmax is what makes this survive a narrow drawer: the
          // grid drops to fewer columns instead of forcing every cell to clip.
          gridTemplateColumns: 'repeat(auto-fit, minmax(140px, 1fr))',
          gap: 8,
        }}
      >
        <Metric
          testId={`${testId}-lef`}
          label="LEF"
          display={loading ? '…' : lef ? formatFrequency(lef.mode) : '—'}
          full={loading ? 'loading' : lef ? formatTriple(lef) : 'unavailable'}
          hint="Loss Event Frequency, events per year"
        />
        <Metric
          testId={`${testId}-lm`}
          label="LM"
          display={lm.display}
          full={lm.full}
          hint="Loss Magnitude, modal loss per event"
        />
        <Metric
          testId={`${testId}-pml`}
          label="PML"
          display={pmlF.display}
          full={pmlF.full}
          hint="Probable Maximum Loss, the 95th-percentile bad year"
        />
        <Metric
          testId={`${testId}-ale`}
          label="ALE"
          display={aleF.display}
          full={aleF.full}
          hint="Annualised Loss Expectancy, mean annual loss"
        />
        {tvar !== undefined && tvar !== null ? (
          <Metric
            testId={`${testId}-tvar`}
            label="TVaR"
            display={tvarF.display}
            full={tvarF.full}
            hint="Tail Value at Risk, mean loss beyond PML"
          />
        ) : null}
      </div>
      {footer ? <div style={{ marginTop: 10 }}>{footer}</div> : null}
    </div>
  )
}

function Header({ title, source, testId }: { title: string; source: FairSource; testId: string }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
      <h3 style={{ margin: 0, fontSize: 13, color: 'var(--muted)', letterSpacing: 0.3 }}>{title}</h3>
      <SourceBadge source={source} testId={`${testId}-source`} />
    </div>
  )
}
