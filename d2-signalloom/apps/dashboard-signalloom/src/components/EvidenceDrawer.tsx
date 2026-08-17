/**
 * EvidenceDrawer — slide-out panel showing the full evidence chain for a
 * provisional actor. Displays observations ordered by timestamp with layer
 * and fidelity badges, connecting the dots from first signal to correlation.
 */
import type { ProvisionalActor, EvidenceLink, SignalLayer, FidelityTier } from '../api/weaveApi'
import { Pill } from './DashKit'

// ─── Layer Display ───────────────────────────────────────────────────────────

const LAYER_LABELS: Record<SignalLayer, string> = {
  network_egress: 'Network/Egress',
  identity_authorization: 'Identity/Auth',
  application_saas: 'Application/SaaS',
  endpoint_host: 'Endpoint/Host',
  behavioural: 'Behavioural',
  cloud_control_plane: 'Cloud Control Plane',
  protocol: 'Protocol',
}

const LAYER_COLORS: Record<SignalLayer, string> = {
  network_egress: 'var(--cyan)',
  identity_authorization: 'var(--violet)',
  application_saas: 'var(--teal)',
  endpoint_host: 'var(--amber)',
  behavioural: 'var(--error)',
  cloud_control_plane: 'var(--dim)',
  protocol: 'var(--dim)',
}

const FIDELITY_LABELS: Record<FidelityTier, string> = {
  definitive: 'Definitive',
  strong: 'Strong',
  suggestive: 'Suggestive',
  circumstantial: 'Circumstantial',
}

// ─── Component ───────────────────────────────────────────────────────────────

interface EvidenceDrawerProps {
  actor: ProvisionalActor | null
  onClose: () => void
}

export default function EvidenceDrawer({ actor, onClose }: EvidenceDrawerProps) {
  if (!actor) return null

  const sorted = [...actor.evidence_chain].sort(
    (a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime(),
  )

  const layerCount = new Set(sorted.map((e) => e.layer)).size

  return (
    <div
      data-testid="evidence-drawer"
      style={{
        position: 'fixed',
        top: 0,
        right: 0,
        bottom: 0,
        width: 520,
        maxWidth: '100vw',
        background: 'var(--surface)',
        borderLeft: '1px solid var(--border)',
        zIndex: 1000,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        boxShadow: '-8px 0 24px rgba(0,0,0,0.3)',
      }}
    >
      {/* Header */}
      <div style={{
        padding: '20px 24px 16px',
        borderBottom: '1px solid var(--border)',
        flexShrink: 0,
      }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 12 }}>
          <div>
            <h2 style={{ fontSize: 18, fontWeight: 700, color: 'var(--text)', margin: 0 }}>
              {actor.display_name ?? actor.id}
            </h2>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
              Evidence Chain — {sorted.length} observations across {layerCount} layers
            </div>
          </div>
          <button
            onClick={onClose}
            aria-label="Close evidence drawer"
            data-testid="evidence-drawer-close"
            style={{
              background: 'none',
              border: 'none',
              color: 'var(--muted)',
              fontSize: 20,
              cursor: 'pointer',
              padding: '4px 8px',
              lineHeight: 1,
            }}
          >
            &times;
          </button>
        </div>

        {/* Confidence derivation */}
        <div style={{
          background: 'var(--surface2)',
          borderRadius: 'var(--radius)',
          padding: '12px 16px',
        }}>
          <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 6 }}>
            Confidence Derivation
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{
              fontSize: 28,
              fontWeight: 700,
              color: actor.confidence >= 0.7 ? 'var(--teal)' : actor.confidence >= 0.5 ? 'var(--amber)' : 'var(--muted)',
            }}>
              {Math.round(actor.confidence * 100)}%
            </div>
            <div style={{ fontSize: 12, color: 'var(--muted)', flex: 1 }}>
              Composite score from {sorted.length} observations.
              {sorted.filter((e) => e.fidelity === 'definitive').length > 0 && (
                <> Includes {sorted.filter((e) => e.fidelity === 'definitive').length} definitive signal{sorted.filter((e) => e.fidelity === 'definitive').length > 1 ? 's' : ''}.</>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* Evidence timeline */}
      <div style={{ flex: 1, overflow: 'auto', padding: '16px 24px' }}>
        {sorted.map((link, i) => (
          <EvidenceItem key={link.observation_id} link={link} isLast={i === sorted.length - 1} />
        ))}
      </div>
    </div>
  )
}

function EvidenceItem({ link, isLast }: { link: EvidenceLink; isLast: boolean }) {
  const layerColor = LAYER_COLORS[link.layer]
  const time = new Date(link.timestamp)
  const timeStr = time.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
  const dateStr = time.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })

  return (
    <div
      data-testid="evidence-item"
      style={{ display: 'flex', gap: 16, marginBottom: isLast ? 0 : 4 }}
    >
      {/* Timeline connector */}
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', width: 20, flexShrink: 0 }}>
        <div style={{
          width: 10,
          height: 10,
          borderRadius: '50%',
          background: layerColor,
          flexShrink: 0,
          marginTop: 4,
        }} />
        {!isLast && (
          <div style={{
            width: 2,
            flex: 1,
            background: 'var(--border)',
            minHeight: 20,
          }} />
        )}
      </div>

      {/* Content */}
      <div style={{ flex: 1, paddingBottom: isLast ? 0 : 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
          <span style={{
            fontSize: 10,
            fontWeight: 600,
            textTransform: 'uppercase',
            letterSpacing: '0.06em',
            color: layerColor,
            background: `${layerColor}1A`,
            padding: '2px 8px',
            borderRadius: 4,
          }}>
            {LAYER_LABELS[link.layer]}
          </span>
          <Pill label={FIDELITY_LABELS[link.fidelity]} />
          <span style={{ fontSize: 11, color: 'var(--dim)', marginLeft: 'auto' }}>
            {dateStr} {timeStr}
          </span>
        </div>
        <div style={{ fontSize: 13, color: 'var(--text)', lineHeight: 1.5 }}>
          {link.contribution}
        </div>
      </div>
    </div>
  )
}

export { LAYER_LABELS, LAYER_COLORS, FIDELITY_LABELS }
