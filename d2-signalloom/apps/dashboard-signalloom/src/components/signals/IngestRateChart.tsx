/**
 * Ingest rate per layer over the window, as a stacked bar per bucket.
 *
 * Stacked rather than grouped because the question an operator asks of this
 * chart is "how much is coming in, and did the mix change", and a stack
 * answers both at once: the total is the bar height and the mix is the
 * segments. One series per layer actually present in the data, so a layer with
 * no collector deployed does not get a permanent empty legend entry.
 */
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts'
import type { IngestRateBucket } from '../../api/policyApi'
import { LAYER_ORDER, bucketTick, layerColor, layerLabel } from './presentation'

export interface RateRow {
  bucket: string
  tick: string
  total: number
  [layer: string]: string | number
}

/**
 * Pivot the long-format rate rows into one row per bucket with a column per
 * layer, which is the shape recharts stacks.
 *
 * Exported so the pivot is testable without a renderer: this is the only real
 * logic in the chart and jsdom cannot see the bars.
 */
export function pivotRates(rates: IngestRateBucket[]): { rows: RateRow[]; layers: string[] } {
  const byBucket = new Map<string, RateRow>()
  const seen = new Set<string>()
  for (const r of rates) {
    seen.add(String(r.layer))
    let row = byBucket.get(r.bucket_start)
    if (!row) {
      row = { bucket: r.bucket_start, tick: bucketTick(r.bucket_start), total: 0 }
      byBucket.set(r.bucket_start, row)
    }
    row[r.layer] = (Number(row[r.layer]) || 0) + r.count
    row.total += r.count
  }
  const rows = [...byBucket.values()].sort((a, b) => a.bucket.localeCompare(b.bucket))
  // Known layers in their canonical order first, so the stack colours are
  // stable as buckets come and go; anything unrecognised follows, sorted.
  const known = LAYER_ORDER.filter((l) => seen.has(l)) as string[]
  const unknown = [...seen].filter((l) => !known.includes(l)).sort()
  return { rows, layers: [...known, ...unknown] }
}

export default function IngestRateChart({ rates }: { rates: IngestRateBucket[] }) {
  const { rows, layers } = pivotRates(rates)

  if (rows.length === 0) {
    return (
      <div data-testid="ingest-rate-empty" style={{ padding: '28px 0', textAlign: 'center', fontSize: 12.5, color: 'var(--muted)' }}>
        No ingest in this window.
      </div>
    )
  }

  return (
    <div data-testid="ingest-rate-chart">
      <ResponsiveContainer width="100%" height={220}>
        <BarChart data={rows} margin={{ top: 8, right: 16, bottom: 0, left: 0 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" vertical={false} />
          <XAxis dataKey="tick" tick={{ fontSize: 11, fill: 'var(--muted)' }} />
          <YAxis tick={{ fontSize: 11, fill: 'var(--muted)' }} allowDecimals={false} />
          <Tooltip
            contentStyle={{ background: 'var(--surface)', border: '1px solid var(--border)', fontSize: 12 }}
            formatter={(value, name) => [value as number, layerLabel(String(name))]}
          />
          <Legend formatter={(name: string) => layerLabel(String(name))} wrapperStyle={{ fontSize: 11 }} />
          {layers.map((layer) => (
            <Bar key={layer} dataKey={layer} stackId="ingest" fill={layerColor(layer)} />
          ))}
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}
