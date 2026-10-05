/**
 * Per-source ingest over the window: how many events, from which layer, and
 * when the last one arrived.
 *
 * Derived from the rate buckets rather than from the observation feed, because
 * the feed is capped (it is the most recent N, not the window) and a source
 * that is firing steadily would otherwise be indistinguishable from one that
 * fired once and stopped.
 */
import type { IngestRateBucket } from '../../api/policyApi'
import { layerColor, layerLabel, thStyle, tdStyle, timeShort } from './presentation'

export interface SourceRow {
  source: string
  layers: string[]
  count: number
  lastSeen: string
}

/** Fold the rate buckets into one row per source, busiest first. */
export function foldSources(rates: IngestRateBucket[]): SourceRow[] {
  const bySource = new Map<string, SourceRow>()
  for (const r of rates) {
    const existing = bySource.get(r.source)
    if (!existing) {
      bySource.set(r.source, {
        source: r.source,
        layers: [String(r.layer)],
        count: r.count,
        lastSeen: r.bucket_start,
      })
      continue
    }
    existing.count += r.count
    if (!existing.layers.includes(String(r.layer))) existing.layers.push(String(r.layer))
    if (r.bucket_start > existing.lastSeen) existing.lastSeen = r.bucket_start
  }
  return [...bySource.values()].sort((a, b) => b.count - a.count || a.source.localeCompare(b.source))
}

export default function SourceTable({ rates }: { rates: IngestRateBucket[] }) {
  const rows = foldSources(rates)

  if (rows.length === 0) {
    return (
      <div data-testid="source-table-empty" style={{ padding: '20px 0', fontSize: 12.5, color: 'var(--muted)' }}>
        No source reported in this window.
      </div>
    )
  }

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }} data-testid="source-table">
      <table style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr style={{ borderBottom: '1px solid var(--border)' }}>
            <th style={thStyle}>Source</th>
            <th style={thStyle}>Layers</th>
            <th style={thStyle}>Events</th>
            <th style={thStyle}>Last seen</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.source} data-testid={`source-row-${row.source}`} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...tdStyle, fontWeight: 600 }}>{row.source}</td>
              <td style={tdStyle}>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {row.layers.map((l) => (
                    <span key={l} style={{ fontSize: 11, fontWeight: 600, color: layerColor(l) }}>
                      {layerLabel(l)}
                    </span>
                  ))}
                </div>
              </td>
              <td style={tdStyle} data-testid="source-count">{row.count}</td>
              <td style={{ ...tdStyle, color: 'var(--muted)' }} data-testid="source-last-seen">
                {timeShort(row.lastSeen)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
