import type { AriaAttributes, CSSProperties, ReactNode } from 'react'

// One shared sync-status pill for every connector/remote-environment surface
// that was previously hand-rolling its own pill (Settings, SyncLogsModal,
// RemoteEnvironmentPage, RemoteSyncBadge). See the design-system audit,
// rules 4 and 12: radius, padding and uppercasing now come from `.tag`
// uniformly instead of five different ad hoc geometries.

export type SyncTone = 'teal' | 'cyan' | 'violet' | 'amber' | 'red' | 'muted'

interface ToneSpec {
  background: string
  border: string
  color: string
  /**
   * Set only for amber/red. The audit's rule 11 measured `--amber` and
   * `--error` as text on their own tint at 3.02-3.39:1 across the three
   * themes — below the 4.5:1 AA floor for 11px text. Rather than recompute
   * that every time a tint mixes with an unknown background, the label is
   * pinned to `--text` (13.98:1 worst case, per LoadingState.tsx's own
   * measurement) and colour is carried by this dot and the border instead,
   * both of which only owe 3:1 as non-text UI.
   */
  dot?: string
}

// Reuses the fixed alpha-ramp tokens (`--teal-bg` etc., global.css) rather
// than StatusBadge's `tint()` helper: Settings.test.tsx asserts the "Synced"
// pill's border literally contains `var(--teal-border)`, and a color-mix()
// value would both break that assertion and buy nothing — the alpha ramp is
// already a valid (if unthemed — global.css rule 2) token, and the audit's
// actual complaint about this pill (rule 11) is a text-contrast issue, not a
// background/border token issue.
const TONE: Record<SyncTone, ToneSpec> = {
  teal: { background: 'var(--teal-bg)', border: 'var(--teal-border)', color: 'var(--teal)' },
  cyan: { background: 'var(--cyan-bg)', border: 'var(--cyan-border)', color: 'var(--cyan)' },
  violet: { background: 'var(--violet-bg)', border: 'var(--violet-border)', color: 'var(--violet)' },
  amber: { background: 'var(--amber-bg)', border: 'var(--amber-border)', color: 'var(--text)', dot: 'var(--amber)' },
  red: { background: 'var(--red-bg)', border: 'var(--red-border)', color: 'var(--text)', dot: 'var(--error)' },
  muted: { background: 'var(--surface)', border: 'var(--border-subtle)', color: 'var(--muted)' },
}

export interface SyncStatusPillProps {
  tone: SyncTone
  label: ReactNode
  testId?: string
  title?: string
  role?: string
  ariaLive?: AriaAttributes['aria-live']
  style?: CSSProperties
}

export default function SyncStatusPill({ tone, label, testId, title, role, ariaLive, style }: SyncStatusPillProps) {
  const t = TONE[tone]
  return (
    <span
      className="tag"
      data-testid={testId}
      title={title}
      role={role}
      aria-live={ariaLive}
      style={{
        background: t.background,
        border: `1px solid ${t.border}`,
        color: t.color,
        ...(t.dot ? { gap: 4 } : null),
        ...style,
      }}
    >
      {t.dot && (
        <span
          aria-hidden="true"
          style={{ width: 6, height: 6, borderRadius: '50%', background: t.dot, flexShrink: 0 }}
        />
      )}
      {label}
    </span>
  )
}
