import type { CSSProperties } from 'react'
import type { PlaneResult } from '../types/api'
import DataTable from './DataTable'

/**
 * Per-plane stun outcomes, rendered so that only `contained` can ever look
 * like success.
 *
 * The mapping is a closed switch with an explicit fall-through to `unknown`:
 * the server's vocabulary is open (see PlaneResult), and the failure this file
 * exists to prevent is an unrecognised or partial word being painted the same
 * green as a plane that actually contained.
 */
export type OutcomeTone = 'contained' | 'partial' | 'failed' | 'simulated' | 'unknown'

export function outcomeTone(outcome: string | null | undefined): OutcomeTone {
  switch (outcome) {
    case 'contained':
      return 'contained'
    case 'partial':
      return 'partial'
    case 'failed':
    case 'not_found':
      return 'failed'
    case 'simulated':
      return 'simulated'
    default:
      return 'unknown'
  }
}

const TONE_COLOUR: Record<OutcomeTone, string> = {
  contained: 'var(--teal)',
  partial: 'var(--amber)',
  failed: 'var(--error)',
  simulated: 'var(--cyan)',
  unknown: 'var(--muted)',
}

function toneStyle(tone: OutcomeTone): CSSProperties {
  return {
    color: TONE_COLOUR[tone],
    border: `1px solid color-mix(in srgb, ${TONE_COLOUR[tone]} 45%, transparent)`,
    background: `color-mix(in srgb, ${TONE_COLOUR[tone]} 10%, transparent)`,
    borderRadius: 4,
    padding: '1px 6px',
    fontWeight: 600,
    whiteSpace: 'nowrap',
  }
}

/** True only when the named plane reported `contained`. Absent is not contained. */
export function planeContained(planes: PlaneResult[] | null | undefined, plane: string): boolean {
  return (planes ?? []).some(p => p.plane === plane && p.outcome === 'contained')
}

const DETAILS_MAX = 120

/** `details` as one line of `key=value` pairs, capped so a large payload cannot swamp the row. */
export function summariseDetails(details: Record<string, unknown> | null | undefined): string {
  if (!details) return ''
  const line = Object.entries(details)
    .map(([k, v]) => `${k}=${typeof v === 'string' ? v : JSON.stringify(v)}`)
    .join(', ')
    .replace(/\s+/g, ' ')
  return line.length > DETAILS_MAX ? `${line.slice(0, DETAILS_MAX - 3)}...` : line
}

const HEADLINE: Record<OutcomeTone, string> = {
  contained: 'Stun contained: every plane reported contained',
  partial: 'Stun partial: containment incomplete, check each plane below',
  failed: 'Stun failed: the agent is not contained',
  simulated: 'Stun simulated: no cluster was touched',
  unknown: 'Stun outcome not recognised',
}

export function StunOverallHeadline({ outcome }: { outcome: string | null | undefined }) {
  const tone = outcomeTone(outcome)
  return (
    <h2
      data-testid="stun-overall-outcome"
      data-outcome={outcome ?? ''}
      className={`stun-outcome stun-outcome--${tone}`}
      style={{ fontSize: 15, fontWeight: 600, margin: '0 0 8px', color: 'var(--text)', display: 'flex', alignItems: 'center', gap: 8 }}
    >
      <span style={{ ...toneStyle(tone), fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.04em' }}>
        {outcome || 'unknown'}
      </span>
      {tone === 'unknown' ? `${HEADLINE.unknown}: ${outcome ?? ''}` : HEADLINE[tone]}
    </h2>
  )
}

export function PlaneOutcomeTable({ planes }: { planes: PlaneResult[] }) {
  if (planes.length === 0) {
    return (
      <p data-testid="stun-plane-table-empty" style={{ fontSize: 12, color: 'var(--muted)', margin: '8px 0' }}>
        The server returned no per-plane report, so no containment is confirmed.
      </p>
    )
  }
  const muted = { ...DataTable.td, color: 'var(--muted)', fontSize: 12 }
  return (
    <table data-testid="stun-plane-table" style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12, margin: '8px 0' }}>
      <thead>
        <tr style={{ borderBottom: '1px solid var(--border)' }}>
          <th style={DataTable.th}>Plane</th>
          <th style={DataTable.th}>Outcome</th>
          <th style={DataTable.th}>Latency</th>
          <th style={DataTable.th}>Error</th>
          <th style={DataTable.th}>Details</th>
        </tr>
      </thead>
      <tbody>
        {planes.map((p, i) => {
          const tone = outcomeTone(p.outcome)
          // A fleet cascade reports one entry per plane PER TARGET, so a name
          // can repeat. The first keeps the plain test id; later ones get -2, -3.
          const nth = planes.slice(0, i).filter(q => q.plane === p.plane).length
          const id = nth === 0 ? p.plane : `${p.plane}-${nth + 1}`
          return (
            <tr key={`${p.plane}-${i}`} data-testid={`stun-plane-row-${id}`} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...DataTable.td, fontFamily: 'monospace' }}>{p.plane}</td>
              <td style={DataTable.td}>
                <span
                  data-testid={`stun-plane-outcome-${id}`}
                  className={`stun-outcome stun-outcome--${tone}`}
                  style={toneStyle(tone)}
                >
                  {p.outcome}
                </span>
              </td>
              <td data-testid={`stun-plane-latency-${id}`} style={muted}>
                {typeof p.latency_ms === 'number' ? `${p.latency_ms} ms` : '-'}
              </td>
              <td data-testid={`stun-plane-error-${id}`} style={{ ...DataTable.td, fontSize: 12 }}>
                {p.error ?? '-'}
              </td>
              <td
                data-testid={`stun-plane-details-${id}`}
                title={p.details ? JSON.stringify(p.details, null, 2) : undefined}
                style={{ ...muted, fontFamily: 'monospace', fontSize: 11, maxWidth: 280, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}
              >
                {summariseDetails(p.details) || '-'}
              </td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}

/** Compact one-line form for places with no room for the table, such as an audit row. */
export function PlaneStrip({ planes, testId }: { planes: PlaneResult[]; testId: string }) {
  return (
    <div data-testid={testId} style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginTop: 4 }}>
      {planes.map((p, i) => {
        const tone = outcomeTone(p.outcome)
        const nth = planes.slice(0, i).filter(q => q.plane === p.plane).length
        const id = nth === 0 ? p.plane : `${p.plane}-${nth + 1}`
        return (
          <span
            key={`${p.plane}-${i}`}
            data-testid={`${testId}-${id}`}
            className={`stun-outcome stun-outcome--${tone}`}
            title={p.error ?? undefined}
            style={{ ...toneStyle(tone), fontSize: 10, fontFamily: 'monospace', fontWeight: 500 }}
          >
            {p.plane}: {p.outcome}
          </span>
        )
      })}
    </div>
  )
}

/**
 * Narrow an untyped audit payload to plane results. Audit `detail` is
 * `Record<string, unknown>`, so this checks shape rather than trusting it.
 */
export function planesFromDetail(detail: Record<string, unknown> | null | undefined): PlaneResult[] | null {
  const raw = detail?.planes
  if (!Array.isArray(raw)) return null
  const planes = raw.filter(
    (p): p is PlaneResult =>
      typeof p === 'object' && p !== null
      && typeof (p as PlaneResult).plane === 'string'
      && typeof (p as PlaneResult).outcome === 'string',
  )
  return planes.length > 0 ? planes : null
}
