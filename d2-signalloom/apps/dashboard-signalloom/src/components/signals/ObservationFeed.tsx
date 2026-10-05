/**
 * The live observation feed: newest first, one line each.
 *
 * What it shows is deliberately narrow: layer, source, pseudonymous actor, the
 * projected one-line description, and metadata chips. It does NOT show
 * `raw_evidence_ref`, which is a pointer into the evidence blob store and is
 * only ever dereferenced server-side behind an audited read. Putting even the
 * reference on screen invites someone to paste it somewhere it does not
 * belong, and it tells an operator nothing they can act on.
 */
import type { SignalObservation } from '../../api/weaveApi'
import { LabelChips, layerColor, layerLabel, timeShort } from './presentation'

export default function ObservationFeed({ observations }: { observations: SignalObservation[] }) {
  if (observations.length === 0) {
    return (
      <div data-testid="observation-feed-empty" style={{ padding: '20px 0', fontSize: 12.5, color: 'var(--muted)' }}>
        No observation in this window yet.
      </div>
    )
  }

  return (
    <div className="card" style={{ padding: '4px 0' }} data-testid="observation-feed">
      {observations.map((obs) => (
        <div
          key={obs.id}
          id={`observation-${obs.id}`}
          data-testid="observation-item"
          style={{
            display: 'flex',
            gap: 12,
            alignItems: 'flex-start',
            padding: '10px 18px',
            borderBottom: '1px solid var(--border)',
          }}
        >
          <span style={{ fontSize: 11, color: 'var(--muted)', width: 64, flexShrink: 0, fontVariantNumeric: 'tabular-nums' }}>
            {timeShort(obs.timestamp)}
          </span>
          <span
            data-testid="observation-layer"
            style={{
              fontSize: 11,
              fontWeight: 600,
              color: layerColor(obs.layer),
              textTransform: 'uppercase',
              letterSpacing: '0.04em',
              width: 140,
              flexShrink: 0,
            }}
          >
            {layerLabel(obs.layer)}
          </span>
          <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 5 }}>
            <div style={{ fontSize: 13, color: 'var(--text)' }}>{obs.description}</div>
            <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center', fontSize: 11, color: 'var(--muted)' }}>
              <span data-testid="observation-source">{obs.source}</span>
              <span data-testid="observation-actor" title="Pseudonymous actor reference">
                {obs.actor_hint ?? 'unattributed'}
              </span>
              <LabelChips labels={obs.labels} />
            </div>
          </div>
        </div>
      ))}
    </div>
  )
}
