/**
 * Shared presentation for the Signals page: layer naming, severity colour,
 * short timestamps, and the one guard that matters, which is the label-chip
 * filter.
 *
 * The signal store holds projected descriptions, not payloads, and the
 * collectors are supposed to strip the body before anything reaches the
 * portal. "Supposed to" is the operative phrase: the browser is the last place
 * a leaked field would be noticed and the first place it would be screenshotted
 * into a deck. `safeLabels` therefore drops any key whose name says it carries
 * content rather than metadata, so a collector regression shows up as a
 * missing chip and not as a payload on a projector.
 */
import type { CSSProperties } from 'react'
import type { SignalLayer } from '../../api/weaveApi'
import type { PolicySeverity } from '../../api/policyApi'

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
  cloud_control_plane: 'var(--slate-gray)',
  protocol: 'var(--dim)',
}

/** A layer's display name, falling back to the wire value for a layer we do not know yet. */
export function layerLabel(layer: string): string {
  return LAYER_LABELS[layer as SignalLayer] ?? layer
}

/** A layer's colour, falling back to the dim token for an unknown layer. */
export function layerColor(layer: string): string {
  return LAYER_COLORS[layer as SignalLayer] ?? 'var(--dim)'
}

/** Every layer the page can chart, in a stable order so colours do not move. */
export const LAYER_ORDER: SignalLayer[] = [
  'network_egress',
  'identity_authorization',
  'application_saas',
  'endpoint_host',
  'behavioural',
  'cloud_control_plane',
  'protocol',
]

const SEVERITY_COLORS: Record<string, string> = {
  critical: 'var(--error)',
  high: 'var(--amber)',
  medium: 'var(--cyan)',
  low: 'var(--teal)',
  info: 'var(--dim)',
}

export function severityColor(severity: PolicySeverity): string {
  return SEVERITY_COLORS[String(severity).toLowerCase()] ?? 'var(--dim)'
}

/**
 * Label keys that are never shown.
 *
 * Matched on whole underscore-delimited words so `raw_body`, `http.payload`
 * and `api_token` are dropped while `destination`, `path_prefix` and
 * `reuse_count` are kept. A key that is merely long is not suspicious; a key
 * that says "body" is.
 */
const UNSAFE_LABEL_KEY = /(^|[._-])(raw|payload|body|content|data|secret|token|password|credential|key|evidence)([._-]|$)/i

/** The labels a chip row may render. */
export function safeLabels(labels?: Record<string, string> | null): Array<[string, string]> {
  if (!labels) return []
  return Object.entries(labels).filter(([k, v]) => !UNSAFE_LABEL_KEY.test(k) && typeof v === 'string')
}

/** `09:04:12` in the operator's locale, or the raw value if it will not parse. */
export function timeShort(iso: string): string {
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return iso
  return new Date(t).toLocaleTimeString('en-GB', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
}

/** `09:04` for a chart tick, where seconds are noise. */
export function bucketTick(iso: string): string {
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return iso
  return new Date(t).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
}

export const chipStyle: CSSProperties = {
  fontSize: 11,
  padding: '2px 8px',
  borderRadius: 4,
  background: 'var(--surface2)',
  border: '1px solid var(--border)',
  color: 'var(--text)',
  whiteSpace: 'nowrap',
}

/** A metadata chip row. Keys that look like content are not rendered at all. */
export function LabelChips({ labels }: { labels?: Record<string, string> | null }) {
  const entries = safeLabels(labels)
  if (entries.length === 0) return null
  return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
      {entries.map(([k, v]) => (
        <span key={k} data-testid={`label-chip-${k}`} style={chipStyle}>
          <span style={{ color: 'var(--muted)' }}>{k}: </span>
          {v}
        </span>
      ))}
    </div>
  )
}

export const thStyle: CSSProperties = {
  padding: '9px 14px',
  textAlign: 'left',
  color: 'var(--muted)',
  fontWeight: 600,
  fontSize: 11,
  textTransform: 'uppercase',
  letterSpacing: '0.05em',
  whiteSpace: 'nowrap',
}

export const tdStyle: CSSProperties = {
  padding: '9px 14px',
  fontSize: 13,
  color: 'var(--text)',
  verticalAlign: 'top',
}
