/**
 * The shared parts every header candidate is assembled from.
 *
 * Kept out of src/components/ proper on purpose: these exist to let five
 * proposals be compared, not to be adopted. When one of the five wins, the
 * pieces it needs get promoted into components/ with their own tests; until
 * then a component that nothing in the app renders should not sit in the
 * drawer where the app's components live.
 *
 * TWO RULES HOLD ACROSS EVERYTHING IN HERE.
 *
 * 1. Colour is never the only carrier. Every severity dot has the severity
 *    word beside it or in the accessible name of the control it sits in. A
 *    reader who cannot separate the amber from the red loses nothing.
 *
 * 2. An accessible name contains the visible label. WCAG 2.5.3, and in this
 *    codebase a CI stage — an aria-label of "Open help and support" on a
 *    button reading "Help & Support" made the control unsayable, which is
 *    what components/sidebarLabelInName.test.tsx now guards. Icon-only
 *    controls here take a name a person would plausibly speak, and every
 *    control that renders a visible number or word puts that number or word
 *    inside its name.
 */
import { useEffect, useRef, type CSSProperties, type ReactNode } from 'react'
import {
  SEVERITY_LABELS,
  SEVERITY_TOKENS,
  alertLinkName,
  toHref,
  type HeaderAlert,
  type Severity,
} from './alerts'

// ── Icons ────────────────────────────────────────────────────────────────────
//
// aria-hidden without exception. An icon that carries meaning does it through
// the accessible name of the control around it, never through a title element
// a screen reader may or may not reach.

const ICON_PROPS = {
  width: 15,
  height: 15,
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.8,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  'aria-hidden': true,
}

export function BellIcon() {
  return (
    <svg {...ICON_PROPS}>
      <path d="M18 9a6 6 0 1 0-12 0c0 5-2 6-2 6h16s-2-1-2-6" />
      <path d="M13.7 19a2 2 0 0 1-3.4 0" />
    </svg>
  )
}

export function SearchIcon() {
  return (
    <svg {...ICON_PROPS}>
      <circle cx="11" cy="11" r="6.5" />
      <path d="m16 16 4.5 4.5" />
    </svg>
  )
}

export function ChevronIcon({ open }: { open: boolean }) {
  return (
    <svg {...ICON_PROPS} style={{ transform: open ? 'rotate(180deg)' : undefined, transition: 'transform var(--motion-fast) var(--ease-signature)' }}>
      <path d="m6 9 6 6 6-6" />
    </svg>
  )
}

export function ArrowIcon() {
  return (
    <svg {...ICON_PROPS} width={13} height={13}>
      <path d="M5 12h13" />
      <path d="m12.5 6 6 6-6 6" />
    </svg>
  )
}

// ── Severity ─────────────────────────────────────────────────────────────────

/**
 * The severity mark. Decorative by construction — the word is always rendered
 * or spoken beside it.
 *
 * Sized 8px and drawn in the severity's own token, which clears the 3:1
 * non-text contrast floor against `--surface` in all three themes (the
 * tightest is `--error` on Dark at 3.63:1). It is not asked to clear the 4.5:1
 * text floor, because it carries no text and never will.
 */
export function SeverityDot({ severity, size = 8 }: { severity: Severity; size?: number }) {
  return (
    <span
      aria-hidden="true"
      data-testid={`dsh-severity-dot-${severity}`}
      style={{
        width: size,
        height: size,
        borderRadius: '50%',
        background: `var(${SEVERITY_TOKENS[severity]})`,
        flexShrink: 0,
        display: 'inline-block',
      }}
    />
  )
}

/** Dot plus word. The default way to show a severity anywhere text will fit. */
export function SeverityTag({ severity }: { severity: Severity }) {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 11, color: 'var(--muted)', flexShrink: 0 }}>
      <SeverityDot severity={severity} />
      {SEVERITY_LABELS[severity]}
    </span>
  )
}

/**
 * The unread count.
 *
 * NOT white-on-red, and that is a deliberate departure from the badge the
 * app's current TopNav draws. `--on-accent` (#FFFFFF everywhere) against
 * `--error` measures 3.85:1 under the Andy theme, and a 11px bold numeral is
 * normal-size text, so it wants 4.5:1. A red pill with an unreadable number on
 * it is a decoration that looks like information.
 *
 * So the urgency is carried by a red-tinted surface and a red hairline, and
 * the numeral is `--text` — near-white on the dark themes, near-black on
 * Light, above 10:1 against the tint in all three. The colour still shouts;
 * the number is still readable; and the count is in the accessible name of
 * whatever control this sits inside, so it is not colour-only either.
 */
export function UnreadPill({ count, testId }: { count: number; testId?: string }) {
  return (
    <span
      aria-hidden="true"
      data-testid={testId}
      style={{
        minWidth: 18,
        padding: '1px 6px',
        borderRadius: 99,
        fontSize: 11,
        fontWeight: 700,
        lineHeight: '16px',
        textAlign: 'center',
        color: 'var(--text)',
        background: 'color-mix(in srgb, var(--error) 22%, var(--surface2))',
        border: '1px solid color-mix(in srgb, var(--error) 55%, transparent)',
      }}
    >
      {count > 99 ? '99+' : count}
    </span>
  )
}

// ── Chrome ───────────────────────────────────────────────────────────────────

/** A small piece of standing state — cluster, tenant, data mode. */
export function Chip({
  label,
  value,
  tone = 'neutral',
  testId,
}: {
  label: string
  value: string
  tone?: 'neutral' | 'accent' | 'warn'
  testId?: string
}) {
  const token = tone === 'accent' ? '--cyan' : tone === 'warn' ? '--amber' : '--border-subtle'
  return (
    <span
      data-testid={testId}
      style={{
        display: 'inline-flex',
        alignItems: 'baseline',
        gap: 6,
        fontSize: 11,
        padding: '2px 8px',
        borderRadius: 'var(--radius-sm)',
        border: `1px solid color-mix(in srgb, var(${token}) 45%, transparent)`,
        background: tone === 'neutral' ? 'transparent' : `color-mix(in srgb, var(${token}) 10%, transparent)`,
        whiteSpace: 'nowrap',
      }}
    >
      <span style={{ color: 'var(--dim)', textTransform: 'uppercase', letterSpacing: '0.06em', fontSize: 9.5 }}>{label}</span>
      <span style={{ color: 'var(--text)', fontWeight: 600 }}>{value}</span>
    </span>
  )
}

/**
 * The frame every candidate is shown inside.
 *
 * The three inert bars underneath are not filler. A header cannot be judged in
 * isolation — the whole question is how much of the reader's screen and
 * attention it takes before the work starts, and a header floating on its own
 * always looks reasonable. They are drawn in `--border` against `--surface`,
 * far below text contrast on purpose: they are furniture, and they carry an
 * aria-hidden so a screen reader never meets them at all.
 */
export function HeaderFrame({ children, testId }: { children: ReactNode; testId: string }) {
  return (
    <div
      data-testid={testId}
      style={{
        border: '1px solid var(--border)',
        borderRadius: 'var(--radius)',
        background: 'var(--surface)',
        overflow: 'hidden',
        position: 'relative',
      }}
    >
      {children}
      <div aria-hidden="true" style={{ padding: '18px 20px 22px', display: 'flex', flexDirection: 'column', gap: 9, background: 'var(--bg)' }}>
        <div style={{ height: 9, width: '38%', borderRadius: 3, background: 'var(--border)' }} />
        <div style={{ height: 9, width: '72%', borderRadius: 3, background: 'var(--border)' }} />
        <div style={{ height: 9, width: '55%', borderRadius: 3, background: 'var(--border)' }} />
      </div>
    </div>
  )
}

export const headerRowStyle: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 12,
  padding: '0 16px',
  background: 'var(--surface)',
  borderBottom: '1px solid var(--border)',
}

/** The woven-diamond mark, at the size a header uses it. Drawn in `--cyan` so it turns with the theme. */
export function Mark({ label = 'Signal Loom' }: { label?: string }) {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8, flexShrink: 0 }}>
      <svg width="20" height="20" viewBox="0 0 28 28" fill="none" aria-hidden="true">
        <path d="M6 14 L14 6 L22 14 L14 22 Z" stroke="var(--cyan)" strokeWidth="2" fill="none" strokeLinejoin="round" />
        <circle cx="14" cy="14" r="2.6" fill="var(--cyan)" />
      </svg>
      <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', letterSpacing: '-0.01em' }}>{label}</span>
    </span>
  )
}

/** The operator's avatar. Initial, not a photo — there are no photos in a fixture. */
export function Avatar({ initial, size = 26 }: { initial: string; size?: number }) {
  return (
    <span
      aria-hidden="true"
      style={{
        width: size,
        height: size,
        borderRadius: '50%',
        background: 'color-mix(in srgb, var(--violet) 24%, var(--surface2))',
        border: '1px solid color-mix(in srgb, var(--violet) 55%, transparent)',
        color: 'var(--text)',
        fontSize: size * 0.46,
        fontWeight: 700,
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        flexShrink: 0,
      }}
    >
      {initial}
    </span>
  )
}

// ── The deep link ────────────────────────────────────────────────────────────

/**
 * One alert, rendered as the link it should be.
 *
 * The resolved href is printed under the headline in monospace. That is not
 * how a shipped header would look and it is the whole reason this page exists:
 * five candidates can all claim to deep-link, and the only way to tell which
 * one actually does is to read the URL it produces. When one of these is
 * adopted the `showHref` prop goes away and nothing else changes.
 *
 * The anchor's accessible name is `title — open <destination>`, so it opens
 * with the visible headline (a speech-input user can still say what they see)
 * and then answers the question the headline does not: where does this land.
 */
export function AlertLink({
  alert,
  showHref = true,
  onDismiss,
  testId,
}: {
  alert: HeaderAlert
  showHref?: boolean
  onDismiss?: (id: string) => void
  testId?: string
}) {
  const href = toHref(alert.target)
  return (
    <div
      data-testid={testId ?? `dsh-alert-${alert.id}`}
      style={{ display: 'flex', alignItems: 'flex-start', gap: 10, padding: '10px 12px', borderBottom: '1px solid var(--border)' }}
    >
      <span style={{ paddingTop: 5 }}>
        <SeverityDot severity={alert.severity} />
      </span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <a
          className="dsh-link"
          href={href}
          aria-label={alertLinkName(alert)}
          data-testid={`dsh-alert-link-${alert.id}`}
          style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--text)', textDecoration: 'none', display: 'block', lineHeight: 1.4 }}
        >
          {alert.title}
        </a>
        <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8, marginTop: 3, fontSize: 11, color: 'var(--muted)' }}>
          <span>{SEVERITY_LABELS[alert.severity]}</span>
          <span aria-hidden="true">·</span>
          <span>{alert.resource}</span>
          <span aria-hidden="true">·</span>
          <span>{alert.age}</span>
        </div>
        {showHref && (
          <code
            data-testid={`dsh-alert-href-${alert.id}`}
            style={{
              display: 'block',
              marginTop: 5,
              fontSize: 10.5,
              lineHeight: 1.45,
              color: 'var(--dim)',
              wordBreak: 'break-all',
            }}
          >
            {href}
          </code>
        )}
      </div>
      {onDismiss && (
        <button
          type="button"
          className="dsh-icon-button"
          onClick={() => onDismiss(alert.id)}
          aria-label={`Dismiss ${alert.title}`}
          data-testid={`dsh-alert-dismiss-${alert.id}`}
          style={{
            background: 'none',
            border: '1px solid transparent',
            borderRadius: 'var(--radius-sm)',
            color: 'var(--muted)',
            fontSize: 15,
            lineHeight: '18px',
            padding: '0 6px',
            cursor: 'pointer',
            flexShrink: 0,
          }}
        >
          {/* aria-hidden: the glyph is a picture of a close box, not a word
              anyone would say. The aria-label carries the name, and naming the
              alert in it is what makes "dismiss" answerable when six of these
              are stacked. */}
          <span aria-hidden="true">×</span>
        </button>
      )}
    </div>
  )
}

// ── Behaviour helpers ────────────────────────────────────────────────────────

/**
 * Close a popover on Escape and on a click outside it.
 *
 * Scoped to the element rather than to `window` for the keydown, so five
 * specimens on one page cannot close each other, and so this page never
 * competes with KeyboardShortcutsOverlay's global `?`/Escape handler. The
 * outside-click listener has to be on the document — that is what "outside"
 * means — but it is only mounted while something is open.
 */
export function useDismissable(open: boolean, close: () => void) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    function onPointerDown(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) close()
    }
    function onKeyDown(e: globalThis.KeyboardEvent) {
      if (e.key === 'Escape') {
        e.stopPropagation()
        close()
      }
    }
    document.addEventListener('mousedown', onPointerDown)
    // Capture phase: this popover is nested inside the page, and Escape should
    // shut the thing the reader just opened rather than bubble past it.
    document.addEventListener('keydown', onKeyDown, true)
    return () => {
      document.removeEventListener('mousedown', onPointerDown)
      document.removeEventListener('keydown', onKeyDown, true)
    }
  }, [open, close])

  return ref
}

/** Move focus into a panel when it opens, and put it back on the trigger when it closes. */
export function useReturnFocus(open: boolean, trigger: React.RefObject<HTMLElement>, target: React.RefObject<HTMLElement>) {
  const wasOpen = useRef(false)
  useEffect(() => {
    if (open) {
      target.current?.focus()
    } else if (wasOpen.current) {
      trigger.current?.focus()
    }
    wasOpen.current = open
  }, [open, trigger, target])
}
