/**
 * SignalBadge — compact pill showing correlated signal observation count,
 * coloured by the highest fidelity tier present. Clickable to navigate
 * to the Signal Weave page.
 */
import type { FidelityTier } from '../api/weaveApi'
import type { SignalLayer } from '../api/weaveApi'

// ─── Fidelity Colour Mapping ────────────────────────────────────────────────

const FIDELITY_COLORS: Record<FidelityTier, string> = {
  definitive: 'var(--teal)',
  strong: 'var(--cyan)',
  suggestive: 'var(--amber)',
  circumstantial: 'var(--muted)',
}

const FIDELITY_BG: Record<FidelityTier, string> = {
  definitive: 'color-mix(in srgb, var(--teal) 12%, transparent)',
  strong: 'color-mix(in srgb, var(--cyan) 12%, transparent)',
  suggestive: 'color-mix(in srgb, var(--amber) 12%, transparent)',
  circumstantial: 'color-mix(in srgb, var(--muted) 12%, transparent)',
}

const FIDELITY_LABELS: Record<FidelityTier, string> = {
  definitive: 'Definitive',
  strong: 'Strong',
  suggestive: 'Suggestive',
  circumstantial: 'Circumstantial',
}

// ─── Status Labels ──────────────────────────────────────────────────────────

const STATUS_LABELS: Record<string, string> = {
  provisional: 'Provisional',
  actionable: 'Actionable',
  promoted: 'Promoted',
}

// ─── Component ──────────────────────────────────────────────────────────────

export interface SignalBadgeProps {
  observationCount: number
  highestFidelity: FidelityTier
  layerCount?: number
  actorStatus?: 'provisional' | 'actionable' | 'promoted'
  onClick?: () => void
  testId?: string
}

export default function SignalBadge({
  observationCount,
  highestFidelity,
  layerCount,
  actorStatus,
  onClick,
  testId,
}: SignalBadgeProps) {
  const color = FIDELITY_COLORS[highestFidelity]
  const bg = FIDELITY_BG[highestFidelity]
  const fidelityLabel = FIDELITY_LABELS[highestFidelity]

  const layers = layerCount ?? 0
  const tooltipParts = [
    `${observationCount} signal observation${observationCount !== 1 ? 's' : ''}`,
  ]
  if (layers > 0) {
    tooltipParts[0] += ` from ${layers} layer${layers !== 1 ? 's' : ''}`
  }
  tooltipParts[0] += ` — highest fidelity: ${fidelityLabel}`

  if (actorStatus) {
    tooltipParts.push(`Actor status: ${STATUS_LABELS[actorStatus] ?? actorStatus}`)
  }

  const tooltip = tooltipParts.join('. ')

  return (
    <span
      className="tag"
      data-testid={testId}
      title={tooltip}
      onClick={onClick}
      role={onClick ? 'button' : undefined}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={onClick ? (e) => { if (e.key === 'Enter' || e.key === ' ') onClick() } : undefined}
      style={{
        background: bg,
        color,
        cursor: onClick ? 'pointer' : 'default',
        display: 'inline-flex',
        alignItems: 'center',
        gap: 5,
        fontSize: 11,
        fontWeight: 600,
        padding: '2px 8px',
        borderRadius: 99,
        whiteSpace: 'nowrap',
        transition: 'opacity 0.15s',
      }}
    >
      <span style={{
        width: 6,
        height: 6,
        borderRadius: '50%',
        background: color,
        flexShrink: 0,
      }} />
      {observationCount} signal{observationCount !== 1 ? 's' : ''}
    </span>
  )
}

export { FIDELITY_COLORS, FIDELITY_LABELS }
export type { SignalLayer as SignalLayerType }
