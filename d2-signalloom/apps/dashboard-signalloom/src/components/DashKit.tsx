/**
 * DashKit — shared presentational primitives for the mock trust/security
 * dashboards (Federated Services, Collusion & Access). Inline-style + CSS-var
 * idiom, matching the existing views.
 */
import { type ReactNode, type CSSProperties } from 'react'
import { colors } from '../styles/tokens'
import HelpHint from './HelpHint'

export function hex(c: string, o: number) {
  return c + Math.round(o * 255).toString(16).padStart(2, '0')
}

const PILL: Record<string, string> = {
  active: colors.tealLoom,
  healthy: colors.tealLoom,
  federated: colors.tealLoom,
  enforced: colors.tealLoom,
  low: colors.tealLoom,
  pass: colors.tealLoom,
  complete: colors.tealLoom,
  pending: colors.cyanLoom,
  connecting: colors.cyanLoom,
  info: colors.cyanLoom,
  running: colors.cyanLoom,
  'never-run': colors.cyanLoom,
  medium: colors.amber,
  degraded: colors.amber,
  warning: colors.amber,
  high: colors.amber,
  critical: colors.red,
  blocked: colors.red,
  revoked: colors.red,
  fail: colors.red,
  error: colors.red,
  failed: colors.red,
  unavailable: colors.red,
}

export function Pill({ label }: { label: string }) {
  const c = PILL[label.toLowerCase()] ?? colors.muted
  return (
    <span className="tag" style={{ background: hex(c, 0.12), color: c }}>
      {label}
    </span>
  )
}

export function StatCard({ label, value, sub, accent }: { label: string; value: string; sub: string; accent: string }) {
  return (
    <div className="card" style={{ flex: 1, minWidth: 180, padding: '16px 18px' }}>
      <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>{label}</div>
      <div style={{ fontSize: 26, fontWeight: 700, color: accent, lineHeight: 1 }}>{value}</div>
      <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>{sub}</div>
    </div>
  )
}

export function Section({ title, hint, children }: { title: string; hint: string; children: ReactNode }) {
  return (
    <section style={{ marginBottom: 26 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 10 }}>
        <h2 style={{ fontSize: 16, fontWeight: 700, color: 'var(--text)' }}>{title}</h2>
        <span style={{ fontSize: 12, color: 'var(--muted)' }}>{hint}</span>
      </div>
      {children}
    </section>
  )
}

const thStyle: CSSProperties = { padding: '9px 14px', textAlign: 'left', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em', whiteSpace: 'nowrap' }
export const td: CSSProperties = { padding: '9px 14px', fontSize: 13, color: 'var(--text)', whiteSpace: 'nowrap' }

/**
 * A column header, optionally carrying a plain-English explanation.
 *
 * Plain strings stay valid so the existing callers are untouched; only the
 * headers whose meaning is genuinely not self-evident pay the cost of an object.
 */
export type TableHeader = string | { label: string; help: string; testId?: string }

export function Table({ headers, children }: { headers: TableHeader[]; children: ReactNode }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'auto' }}>
      <table style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
            {headers.map((h) => {
              const label = typeof h === 'string' ? h : h.label
              return (
                <th key={label} style={thStyle}>
                  {typeof h === 'string' ? label : (
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                      {label}
                      <HelpHint label={`What ${label} means`} testId={h.testId}>{h.help}</HelpHint>
                    </span>
                  )}
                </th>
              )
            })}
          </tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  )
}
