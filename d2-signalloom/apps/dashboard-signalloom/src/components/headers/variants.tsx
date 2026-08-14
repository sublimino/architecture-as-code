/**
 * The five top-bar candidates.
 *
 * Each is a whole argument about what a header is for, not a restyling of the
 * one above it:
 *
 *   1. CommandBarHeader     the header is a way in    — search-first
 *   2. ContextBarHeader     the header is a place     — orientation-first
 *   3. OperationsHeader     the header is an instrument panel — state-first
 *   4. QuietHeader          the header is a label     — restraint-first
 *   5. SituationHeader      the header is an exception channel — event-first
 *
 * All five are driven by the same six alerts from ./alerts, because the only
 * question worth asking of them is how the same world looks through each. All
 * five are local-state only: no router, no context, no API. Every one of them
 * would take a `<Link>` in place of its `<a>` on adoption and nothing else
 * would move.
 */
import { useCallback, useMemo, useRef, useState } from 'react'
import {
  ALERTS,
  COMMANDS,
  CRUMBS,
  ENVIRONMENT,
  OPERATOR,
  SEVERITIES,
  SEVERITY_LABELS,
  SEVERITY_TOKENS,
  alertLinkName,
  bySeverity,
  countBySeverity,
  highestSeverity,
  toHref,
  type HeaderAlert,
} from './alerts'
import {
  AlertLink,
  ArrowIcon,
  Avatar,
  BellIcon,
  ChevronIcon,
  Chip,
  HeaderFrame,
  Mark,
  SearchIcon,
  SeverityDot,
  SeverityTag,
  UnreadPill,
  headerRowStyle,
  useDismissable,
  useReturnFocus,
} from './primitives'

/** Shared by every panel that hangs off a header: same elevation, same edge. */
const panelStyle: React.CSSProperties = {
  position: 'absolute',
  zIndex: 20,
  background: 'var(--surface)',
  border: '1px solid var(--border-subtle)',
  borderRadius: 'var(--radius)',
  boxShadow: '0 12px 32px rgba(0,0,0,0.38)',
  overflow: 'hidden',
}

const kbdStyle: React.CSSProperties = {
  background: 'var(--surface2)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-sm)',
  color: 'var(--dim)',
  fontSize: 10,
  lineHeight: '16px',
  padding: '0 5px',
  display: 'inline-block',
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Command bar
// ─────────────────────────────────────────────────────────────────────────────

/**
 * The header as a way in.
 *
 * One input, and everything else — navigation, alerts, actions — is a result
 * inside it. The claim is that a product whose left rail already carries
 * navigation does not need a second navigation across the top, and that an
 * expert operator reaches for a noun ("sbom-collector", "POL-118") far more
 * often than for a menu.
 *
 * Alerts are a result group rather than a bell, which is the interesting part
 * and the risky part: it means there is exactly one place to go for anything,
 * and it means an unattended alert is behind an interaction rather than in
 * front of the reader. The count is therefore surfaced outside the palette as
 * a button of its own — hiding it entirely would be the version of this that
 * fails in an operations centre.
 *
 * KEYBOARD. Tab reaches the input; ArrowDown from the input moves into the
 * results, which are real links and buttons rather than aria-activedescendant
 * bookkeeping, so Tab keeps working inside them and a screen reader meets each
 * one as the link it is. Escape closes and returns focus to the input. There
 * is no global hotkey: five specimens sharing one page cannot each own `/`,
 * and this page must not race KeyboardShortcutsOverlay's window handler.
 */
export function CommandBarHeader() {
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)
  const firstResultRef = useRef<HTMLAnchorElement>(null)

  const close = useCallback(() => {
    setOpen(false)
    inputRef.current?.focus()
  }, [])
  const containerRef = useDismissable(open, () => setOpen(false))

  const q = query.trim().toLowerCase()
  const commands = useMemo(
    () => COMMANDS.filter((c) => !q || c.label.toLowerCase().includes(q) || c.group.toLowerCase().includes(q)),
    [q],
  )
  const alerts = useMemo(
    () =>
      bySeverity(ALERTS).filter(
        (a) => !q || a.title.toLowerCase().includes(q) || a.resource.toLowerCase().includes(q) || 'alert'.includes(q),
      ),
    [q],
  )

  const unread = ALERTS.length

  function openWith(next: string) {
    setQuery(next)
    setOpen(true)
    inputRef.current?.focus()
  }

  return (
    <HeaderFrame testId="dsh-variant-command">
      <div ref={containerRef} style={{ ...headerRowStyle, height: 52, position: 'relative' }}>
        <Mark />

        <div style={{ flex: 1, display: 'flex', justifyContent: 'center', minWidth: 0 }}>
          <div style={{ position: 'relative', width: '100%', maxWidth: 420 }}>
            <label
              className="dsh-search"
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 8,
                height: 32,
                padding: '0 10px',
                borderRadius: 'var(--radius-sm)',
                border: '1px solid var(--border-subtle)',
                background: 'var(--bg)',
                color: 'var(--muted)',
              }}
            >
              <SearchIcon />
              <input
                ref={inputRef}
                value={query}
                onChange={(e) => {
                  setQuery(e.target.value)
                  setOpen(true)
                }}
                onFocus={() => setOpen(true)}
                onKeyDown={(e) => {
                  if (e.key === 'Escape') {
                    e.stopPropagation()
                    setOpen(false)
                  }
                  if (e.key === 'ArrowDown') {
                    e.preventDefault()
                    setOpen(true)
                    firstResultRef.current?.focus()
                  }
                }}
                type="text"
                placeholder="Search agents, controls and alerts"
                aria-label="Search agents, controls and alerts"
                aria-expanded={open}
                aria-controls="dsh-command-results"
                data-testid="dsh-command-input"
                style={{
                  flex: 1,
                  minWidth: 0,
                  background: 'none',
                  border: 'none',
                  outline: 'none',
                  color: 'var(--text)',
                  fontSize: 12.5,
                }}
              />
              <kbd aria-hidden="true" style={kbdStyle}>⌘K</kbd>
            </label>

            {open && (
              <div id="dsh-command-results" data-testid="dsh-command-palette" style={{ ...panelStyle, top: 38, left: 0, right: 0, maxHeight: 300, overflowY: 'auto' }}>
                <PaletteGroup title="Alerts">
                  {alerts.length === 0 && <PaletteEmpty>No alert matches “{query}”</PaletteEmpty>}
                  {alerts.map((alert, i) => (
                    <a
                      key={alert.id}
                      ref={i === 0 ? firstResultRef : undefined}
                      className="dsh-result"
                      href={toHref(alert.target)}
                      aria-label={alertLinkName(alert)}
                      data-testid={`dsh-command-alert-${alert.id}`}
                      onKeyDown={(e) => {
                        if (e.key === 'Escape') {
                          e.stopPropagation()
                          close()
                        }
                      }}
                      style={resultStyle}
                    >
                      <SeverityDot severity={alert.severity} />
                      <span style={{ flex: 1, minWidth: 0, color: 'var(--text)' }}>{alert.title}</span>
                      <span style={{ color: 'var(--dim)', fontSize: 10.5, flexShrink: 0 }}>{SEVERITY_LABELS[alert.severity]}</span>
                    </a>
                  ))}
                </PaletteGroup>

                <PaletteGroup title="Commands">
                  {commands.length === 0 && <PaletteEmpty>No command matches “{query}”</PaletteEmpty>}
                  {commands.map((cmd) => (
                    <button
                      key={cmd.id}
                      type="button"
                      className="dsh-result"
                      data-testid={`dsh-command-item-${cmd.id}`}
                      onKeyDown={(e) => {
                        if (e.key === 'Escape') {
                          e.stopPropagation()
                          close()
                        }
                      }}
                      style={{ ...resultStyle, width: '100%', textAlign: 'left', background: 'none', border: 'none', cursor: 'pointer' }}
                    >
                      <span style={{ color: 'var(--dim)', fontSize: 10.5, width: 54, flexShrink: 0 }}>{cmd.group}</span>
                      <span style={{ flex: 1, minWidth: 0, color: 'var(--text)' }}>{cmd.label}</span>
                      {cmd.hint && <kbd aria-hidden="true" style={kbdStyle}>{cmd.hint}</kbd>}
                    </button>
                  ))}
                </PaletteGroup>
              </div>
            )}
          </div>
        </div>

        <button
          type="button"
          className="dsh-icon-button"
          onClick={() => openWith('alert')}
          aria-label={`${unread} unread alerts — search them`}
          data-testid="dsh-command-unread"
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            gap: 6,
            background: 'none',
            border: '1px solid var(--border)',
            borderRadius: 'var(--radius-sm)',
            color: 'var(--muted)',
            fontSize: 11.5,
            padding: '4px 8px',
            cursor: 'pointer',
            flexShrink: 0,
          }}
        >
          <UnreadPill count={unread} testId="dsh-command-unread-count" />
          unread
        </button>
        <Avatar initial={OPERATOR.initial} size={24} />
      </div>
    </HeaderFrame>
  )
}

const resultStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 10,
  padding: '7px 12px',
  fontSize: 12.5,
  textDecoration: 'none',
  color: 'var(--text)',
}

function PaletteGroup({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={{ borderBottom: '1px solid var(--border)' }}>
      <div style={{ fontSize: 9.5, letterSpacing: '0.08em', textTransform: 'uppercase', color: 'var(--dim)', padding: '8px 12px 4px' }}>
        {title}
      </div>
      {children}
    </div>
  )
}

function PaletteEmpty({ children }: { children: React.ReactNode }) {
  return <p style={{ margin: 0, padding: '6px 12px 10px', fontSize: 11.5, color: 'var(--muted)' }}>{children}</p>
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Context bar
// ─────────────────────────────────────────────────────────────────────────────

/** The alerts that belong to the thing the reader is currently looking at. */
const SCOPED_ALERTS = ALERTS.filter((a) => a.target.path.startsWith('/compliance/eu-ai-act'))

/**
 * The header as a place.
 *
 * Two lines that answer two different questions. The first is "where am I",
 * which this app asks constantly and never answers: /compliance/:frameworkId
 * and /discovery/accounts/:accountId are three clicks deep with nothing in the
 * chrome saying so, and the browser back button is the only trail. The second
 * is "what is this thing and what state is it in" — the entity's own title,
 * its status, and the actions that apply to it rather than to the app.
 *
 * Notifications are deliberately scoped: "2 alerts on this control", not "6
 * alerts". That is the strongest and the most dangerous idea in the five. It
 * makes the alert relevant — a reader on Article 14 cares about Article 14 —
 * and it means an alert somewhere else in the estate is invisible from here,
 * which is why the count of everything else is still printed beside it as a
 * way out.
 */
export function ContextBarHeader() {
  const [expanded, setExpanded] = useState(false)
  const elsewhere = ALERTS.length - SCOPED_ALERTS.length

  return (
    <HeaderFrame testId="dsh-variant-context">
      <div style={{ background: 'var(--surface)', borderBottom: '1px solid var(--border)' }}>
        <nav aria-label="Breadcrumb" style={{ padding: '8px 16px 0' }}>
          <ol style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 6, listStyle: 'none', margin: 0, padding: 0, fontSize: 11.5 }}>
            {CRUMBS.map((crumb, i) => (
              <li key={crumb.label} style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                {i > 0 && <span aria-hidden="true" style={{ color: 'var(--dim)' }}>›</span>}
                {crumb.href ? (
                  <a
                    className="dsh-link"
                    href={crumb.href}
                    data-testid={`dsh-crumb-${i}`}
                    style={{ color: 'var(--muted)', textDecoration: 'none' }}
                  >
                    {crumb.label}
                  </a>
                ) : (
                  <span aria-current="page" data-testid={`dsh-crumb-${i}`} style={{ color: 'var(--text)', fontWeight: 600 }}>
                    {crumb.label}
                  </span>
                )}
              </li>
            ))}
          </ol>
        </nav>

        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap', padding: '6px 16px 10px' }}>
          <h4 style={{ margin: 0, fontSize: 15, fontWeight: 700, color: 'var(--text)' }}>Human oversight</h4>
          <Chip label="Control" value="ART-14-3" testId="dsh-context-control" />
          <Chip label="State" value="Failing" tone="warn" testId="dsh-context-state" />
          <span style={{ flex: 1 }} />

          <button
            type="button"
            className="dsh-icon-button"
            onClick={() => setExpanded((v) => !v)}
            aria-expanded={expanded}
            aria-controls="dsh-context-scoped-alerts"
            aria-label={`${SCOPED_ALERTS.length} alerts on this control`}
            data-testid="dsh-context-scoped-toggle"
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 7,
              background: 'none',
              border: '1px solid color-mix(in srgb, var(--amber) 45%, transparent)',
              borderRadius: 'var(--radius-sm)',
              color: 'var(--text)',
              fontSize: 11.5,
              padding: '4px 9px',
              cursor: 'pointer',
            }}
          >
            <SeverityDot severity="critical" />
            {SCOPED_ALERTS.length} alerts on this control
            <ChevronIcon open={expanded} />
          </button>

          <a className="dsh-link" href="/audit" data-testid="dsh-context-elsewhere" style={{ fontSize: 11, color: 'var(--muted)' }}>
            {elsewhere} elsewhere
          </a>
        </div>

        {expanded && (
          <div id="dsh-context-scoped-alerts" data-testid="dsh-context-scoped-panel" style={{ borderTop: '1px solid var(--border)', background: 'var(--bg)' }}>
            {SCOPED_ALERTS.map((alert) => (
              <AlertLink key={alert.id} alert={alert} testId={`dsh-context-alert-${alert.id}`} />
            ))}
          </div>
        )}
      </div>
    </HeaderFrame>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Operations console
// ─────────────────────────────────────────────────────────────────────────────

/**
 * The header as an instrument panel.
 *
 * A thin strip above naming what the reader is pointed at, and a working row
 * below. The strip is the entire reason this variant exists: in a bank, the
 * expensive mistake is not misreading a number, it is suspending the right
 * agent in the wrong cluster, and no amount of care in the page below fixes a
 * shell that never says which cluster it is. `Demo data` sits in that strip
 * for the same reason — this product is demonstrated far more often than it is
 * operated, and a figure that is fictional should say so in the chrome rather
 * than in the presenter's narration.
 *
 * The bell is a drawer, not a page, because triage is a sequence: read, judge,
 * dismiss, next. Sending someone to /alerts to dismiss one thing and come back
 * is four navigations for one decision. It groups by severity, dismisses in
 * place, and every row carries the full deep link.
 *
 * This is the most chrome of the five — 84px before any work starts — and the
 * honest cost is that on a 13" laptop it is a visible fraction of the screen.
 */
export function OperationsHeader() {
  const [dismissed, setDismissed] = useState<string[]>([])
  const [open, setOpen] = useState(false)
  const bellRef = useRef<HTMLButtonElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)

  const close = useCallback(() => setOpen(false), [])
  const containerRef = useDismissable(open, close)
  useReturnFocus(open, bellRef, closeRef)

  const live = ALERTS.filter((a) => !dismissed.includes(a.id))
  const counts = countBySeverity(live)

  function dismiss(id: string) {
    setDismissed((prev) => [...prev, id])
  }

  return (
    <HeaderFrame testId="dsh-variant-operations">
      {/* Environment strip */}
      <div
        data-testid="dsh-operations-env-strip"
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          flexWrap: 'wrap',
          padding: '5px 16px',
          background: 'var(--surface2)',
          borderBottom: '1px solid var(--border)',
        }}
      >
        <Chip label="Tenant" value={ENVIRONMENT.tenant} testId="dsh-operations-tenant" />
        <Chip label="Cluster" value={ENVIRONMENT.cluster} tone="accent" testId="dsh-operations-cluster" />
        <Chip label="Region" value={ENVIRONMENT.region} testId="dsh-operations-region" />
        <Chip label="Data" value={ENVIRONMENT.dataMode} tone="warn" testId="dsh-operations-data-mode" />
        <span style={{ flex: 1 }} />
        {ENVIRONMENT.superadmin && (
          <Chip label="Superadmin" value="Active" tone="accent" testId="dsh-operations-superadmin" />
        )}
      </div>

      {/* Working row */}
      <div ref={containerRef} style={{ ...headerRowStyle, height: 52, position: 'relative' }}>
        <Mark />
        <span style={{ fontSize: 13, color: 'var(--dim)' }} aria-hidden="true">/</span>
        <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>Agent Posture</span>
        <span style={{ flex: 1 }} />

        <button
          type="button"
          className="dsh-icon-button"
          aria-label="Search agents, controls and alerts"
          data-testid="dsh-operations-search"
          style={{
            display: 'inline-flex',
            alignItems: 'center',
            gap: 8,
            height: 28,
            padding: '0 9px',
            borderRadius: 'var(--radius-sm)',
            border: '1px solid var(--border-subtle)',
            background: 'var(--bg)',
            color: 'var(--muted)',
            fontSize: 11.5,
            cursor: 'pointer',
          }}
        >
          <SearchIcon />
          Search
          <kbd aria-hidden="true" style={kbdStyle}>⌘K</kbd>
        </button>

        <div style={{ position: 'relative' }}>
          <button
            ref={bellRef}
            type="button"
            className="dsh-icon-button"
            onClick={() => setOpen((v) => !v)}
            aria-expanded={open}
            aria-controls="dsh-operations-drawer"
            aria-label={
              live.length === 0
                ? 'Notifications, none unread'
                : `Notifications, ${live.length} unread, ${counts.critical} critical`
            }
            data-testid="dsh-operations-bell"
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
              height: 28,
              padding: '0 8px',
              borderRadius: 'var(--radius-sm)',
              border: '1px solid var(--border)',
              background: 'none',
              color: 'var(--muted)',
              cursor: 'pointer',
            }}
          >
            <BellIcon />
            {live.length > 0 && <UnreadPill count={live.length} testId="dsh-operations-unread-count" />}
          </button>

          {open && (
            <div
              id="dsh-operations-drawer"
              data-testid="dsh-operations-drawer"
              role="group"
              aria-label="Notifications"
              style={{ ...panelStyle, top: 34, right: 0, width: 400, maxWidth: '86vw', maxHeight: 360, display: 'flex', flexDirection: 'column' }}
            >
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 12px', borderBottom: '1px solid var(--border)' }}>
                <strong style={{ fontSize: 12.5, color: 'var(--text)' }}>Notifications</strong>
                <span style={{ display: 'flex', gap: 10 }}>
                  {SEVERITIES.map((s) => (
                    <span key={s} style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 10.5, color: 'var(--muted)' }}>
                      <SeverityDot severity={s} size={7} />
                      {counts[s]} {SEVERITY_LABELS[s].toLowerCase()}
                    </span>
                  ))}
                </span>
                <span style={{ flex: 1 }} />
                <button
                  ref={closeRef}
                  type="button"
                  className="dsh-icon-button"
                  onClick={close}
                  aria-label="Close notifications"
                  data-testid="dsh-operations-drawer-close"
                  style={{ background: 'none', border: 'none', color: 'var(--muted)', fontSize: 17, lineHeight: 1, padding: '0 3px', cursor: 'pointer' }}
                >
                  <span aria-hidden="true">×</span>
                </button>
              </div>

              <div style={{ flex: 1, overflowY: 'auto' }}>
                {live.length === 0 ? (
                  <p data-testid="dsh-operations-empty" style={{ margin: 0, padding: '22px 14px', fontSize: 12, color: 'var(--muted)', textAlign: 'center' }}>
                    Nothing outstanding. Dismissed alerts stay in the audit trail.
                  </p>
                ) : (
                  bySeverity(live).map((alert) => (
                    <AlertLink key={alert.id} alert={alert} onDismiss={dismiss} testId={`dsh-operations-alert-${alert.id}`} />
                  ))
                )}
              </div>

              <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 12px', borderTop: '1px solid var(--border)', background: 'var(--surface2)' }}>
                <button
                  type="button"
                  className="dsh-icon-button"
                  onClick={() => setDismissed(ALERTS.map((a) => a.id))}
                  data-testid="dsh-operations-dismiss-all"
                  style={{ background: 'none', border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-sm)', color: 'var(--muted)', fontSize: 11, padding: '3px 8px', cursor: 'pointer' }}
                >
                  Dismiss all
                </button>
                <span style={{ flex: 1 }} />
                <a className="dsh-link" href="/audit?view=alerts" data-testid="dsh-operations-inbox-link" style={{ fontSize: 11, color: 'var(--cyan)' }}>
                  Open the full inbox
                </a>
              </div>
            </div>
          )}
        </div>

        <Avatar initial={OPERATOR.initial} size={26} />
      </div>
    </HeaderFrame>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Quiet header
// ─────────────────────────────────────────────────────────────────────────────

/**
 * The header as a label.
 *
 * Forty-four pixels: the mark, where you are, the single worst thing that is
 * true, and who you are. Nothing opens. The alert is a link, not a drawer,
 * and it shows one alert because a header that can only show one is forced to
 * pick the right one — which is a better constraint than it sounds.
 *
 * The state that matters here is the empty one, so the specimen ships with a
 * control to reach it. "All clear" is the state a demo audience spends most of
 * its time looking at, it is the state most designs never draw, and a header
 * whose alert slot collapses to nothing when there is nothing to say is worth
 * more than one that renders a grey zero.
 */
export function QuietHeader({ alerts }: { alerts: HeaderAlert[] }) {
  const top = highestSeverity(alerts)

  return (
    <HeaderFrame testId="dsh-variant-quiet">
      <div style={{ ...headerRowStyle, height: 44 }}>
        <Mark />
        <span style={{ fontSize: 12.5, color: 'var(--dim)' }} aria-hidden="true">/</span>
        <span style={{ fontSize: 12.5, color: 'var(--muted)' }}>Agent Posture</span>
        <span style={{ flex: 1 }} />

        {top ? (
          <a
            className="dsh-link"
            href={toHref(top.target)}
            aria-label={alertLinkName(top)}
            data-testid="dsh-quiet-alert"
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 8,
              maxWidth: 420,
              padding: '4px 9px',
              borderRadius: 'var(--radius-sm)',
              border: `1px solid color-mix(in srgb, var(${SEVERITY_TOKENS[top.severity]}) 45%, transparent)`,
              background: `color-mix(in srgb, var(${SEVERITY_TOKENS[top.severity]}) 9%, transparent)`,
              color: 'var(--text)',
              fontSize: 11.5,
              textDecoration: 'none',
            }}
          >
            <SeverityDot severity={top.severity} />
            <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{top.title}</span>
            <ArrowIcon />
          </a>
        ) : (
          <span data-testid="dsh-quiet-clear" style={{ fontSize: 11.5, color: 'var(--muted)' }}>
            All clear
          </span>
        )}

        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 7, flexShrink: 0 }}>
          <Avatar initial={OPERATOR.initial} size={24} />
          <span style={{ fontSize: 11.5, color: 'var(--muted)' }}>{OPERATOR.name}</span>
        </span>
      </div>
    </HeaderFrame>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Situation header
// ─────────────────────────────────────────────────────────────────────────────

/**
 * The header as an exception channel.
 *
 * At rest it is a hairline and a page name — less chrome than any of the other
 * four. When something breaks it promotes into a banner that is impossible to
 * miss, states what happened and which resource, and offers exactly two
 * things: go to the thing, or acknowledge it. Acknowledging demotes it again.
 *
 * The argument is that a permanent instrument panel is read attentively for
 * about a week and is furniture thereafter, whereas chrome that appears only
 * when it has something to say is still being read in year two. The argument
 * against is in its when-to-use line and it is a real one: an estate where
 * something is always wrong turns this into a banner that is always on, which
 * is a permanent instrument panel with worse layout stability.
 *
 * LIVE REGION. The promoted banner carries `role="alert"` and is the only live
 * region this page mounts. It exists only while promoted and only ever after
 * a click, so a reader who opens the page meets silence — which is the correct
 * behaviour for a gallery and, not coincidentally, for the real thing.
 */
export function SituationHeader() {
  const [incident, setIncident] = useState<HeaderAlert | null>(null)
  const acknowledgeRef = useRef<HTMLButtonElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)

  const promote = useCallback(() => {
    setIncident(highestSeverity(ALERTS) ?? null)
    // Focus follows the escalation: the reader's next decision is in the banner.
    window.setTimeout(() => acknowledgeRef.current?.focus(), 0)
  }, [])

  const acknowledge = useCallback(() => {
    setIncident(null)
    triggerRef.current?.focus()
  }, [])

  return (
    <div>
      <HeaderFrame testId="dsh-variant-situation">
        {incident ? (
          <div
            role="alert"
            data-testid="dsh-situation-banner"
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 12,
              flexWrap: 'wrap',
              padding: '12px 16px',
              background: `color-mix(in srgb, var(${SEVERITY_TOKENS[incident.severity]}) 14%, var(--surface))`,
              borderBottom: `2px solid var(${SEVERITY_TOKENS[incident.severity]})`,
            }}
          >
            <SeverityDot severity={incident.severity} size={10} />
            <div style={{ minWidth: 0, flex: 1 }}>
              <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)' }}>{incident.title}</div>
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                {SEVERITY_LABELS[incident.severity]} · {incident.resource} · first seen {incident.age}
              </div>
            </div>
            <a
              className="dsh-link"
              href={toHref(incident.target)}
              // Not alertLinkName here: the visible words are "Go to
              // agent/sbom-collector", and an accessible name that opened with
              // the headline instead would be a name containing none of the
              // label a speech-input user can see.
              aria-label={`Go to ${incident.resource} — ${incident.destination}`}
              data-testid="dsh-situation-deep-link"
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: 7,
                padding: '5px 11px',
                borderRadius: 'var(--radius-sm)',
                border: `1px solid var(${SEVERITY_TOKENS[incident.severity]})`,
                color: 'var(--text)',
                fontSize: 12,
                fontWeight: 600,
                textDecoration: 'none',
                whiteSpace: 'nowrap',
              }}
            >
              Go to {incident.resource}
              <ArrowIcon />
            </a>
            <button
              ref={acknowledgeRef}
              type="button"
              className="dsh-icon-button"
              onClick={acknowledge}
              data-testid="dsh-situation-acknowledge"
              style={{
                background: 'none',
                border: '1px solid var(--border-subtle)',
                borderRadius: 'var(--radius-sm)',
                color: 'var(--muted)',
                fontSize: 12,
                padding: '5px 11px',
                cursor: 'pointer',
                whiteSpace: 'nowrap',
              }}
            >
              Acknowledge
            </button>
          </div>
        ) : (
          <div data-testid="dsh-situation-rest" style={{ ...headerRowStyle, height: 38 }}>
            <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--text)' }}>Agent Posture</span>
            <span style={{ flex: 1 }} />
            <SeverityTag severity="info" />
            <span style={{ fontSize: 11, color: 'var(--muted)' }}>All clear</span>
          </div>
        )}
      </HeaderFrame>

      <div style={{ marginTop: 10 }}>
        <button
          ref={triggerRef}
          type="button"
          className="btn btn-secondary"
          onClick={promote}
          disabled={incident !== null}
          data-testid="dsh-situation-simulate"
          style={{ fontSize: 11.5, padding: '4px 10px' }}
        >
          Simulate a critical incident
        </button>
        <span style={{ fontSize: 11, color: 'var(--muted)', marginLeft: 10 }}>
          Acknowledging demotes the header back to its resting height.
        </span>
      </div>
    </div>
  )
}
