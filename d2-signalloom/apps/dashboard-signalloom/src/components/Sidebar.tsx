/* Adapted interaction pattern from Beautiful UI Sidebar Nav (MIT); see
 * THIRD_PARTY_NOTICES.md. Signal Loom owns routes, tokens, and semantics. */
import { useState, useEffect, useLayoutEffect, useRef } from 'react'
import { NavLink, useLocation, useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { useAppContext } from '../App'
import { isSuperadminEligible } from '../auth/superadmin'
import { api } from '../api/client'
import type { TenantSettingsResponse } from '../types/api'
import HelpModal from './HelpModal'
import ApiKeyRevealModal from './ApiKeyRevealModal'

export interface NavItem {
  to: string
  label: string
  section: 'Workspace' | 'Governance' | 'Configuration'
  icon: IconKind
  end?: boolean
  superadminOnly?: boolean
}

// One glyph per destination — never share a kind between two nav items. A
// collapsed sidebar is icons only, so a duplicated glyph is an unreadable nav.
export type IconKind =
  | 'discovery' | 'agents' | 'compliance' | 'policies' | 'posture' | 'risk'
  | 'audit' | 'crypto' | 'credentials' | 'federation' | 'access'
  | 'rbacAnalysis' | 'rbacExplorer' | 'network' | 'supercred' | 'fleet'
  | 'topology' | 'designSystem' | 'settings'

function NavIcon({ kind }: { kind: IconKind }) {
  const paths: Record<IconKind, React.ReactNode> = {
    discovery: <><circle cx="11" cy="11" r="6" /><path d="m16 16 4 4M11 8v6M8 11h6" /></>,
    agents: <><rect x="4" y="4" width="16" height="16" rx="3" /><path d="M8 12h8M12 8v8" /></>,
    compliance: <><path d="M12 3 5 6v5c0 5 3 8 7 10 4-2 7-5 7-10V6l-7-3Z" /><path d="m9 12 2 2 4-4" /></>,
    // Document with a tick — a written, ratified policy.
    policies: <><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8l-5-5Z" /><path d="M14 3v5h5" /><path d="m9 15 2 2 3.5-3.5" /></>,
    // Gauge — posture is a measured score, not a binary.
    posture: <><path d="M4 17a8 8 0 1 1 16 0" /><path d="m12 17 4.5-5.2" /><circle cx="12" cy="17" r="1.2" /></>,
    risk: <><path d="M12 4 2.6 20h18.8L12 4Z" /><path d="M12 10v4" /><path d="M12 17.4h.01" /></>,
    audit: <><path d="M5 4h14v16H5z" /><path d="M8 8h8M8 12h8M8 16h5" /></>,
    // Certificate with a ribbon — keeps Cryptography off the shield motif that
    // Compliance already owns.
    crypto: <><rect x="4" y="4" width="16" height="11" rx="2" /><circle cx="12" cy="9.5" r="2.3" /><path d="m9.6 14.6-1.1 5.4 3.5-2.1 3.5 2.1-1.1-5.4" /></>,
    credentials: <><circle cx="8" cy="15" r="3" /><path d="m10 13 7-7 2 2-7 7M14 9l2 2" /></>,
    federation: <><circle cx="7" cy="12" r="3" /><circle cx="17" cy="7" r="3" /><circle cx="17" cy="17" r="3" /><path d="m10 11 4-3M10 13l4 3" /></>,
    access: <><circle cx="12" cy="8" r="3" /><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6M19 8v4M17 10h4" /></>,
    // Bar chart — RBAC Analysis aggregates; RBAC Explorer inspects.
    rbacAnalysis: <><path d="M4 20h16" /><path d="M7 17v-6M12 17V7M17 17v-4" /></>,
    rbacExplorer: <><path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4z" /><circle cx="16.5" cy="16.5" r="3" /><path d="m18.8 18.8 2.2 2.2" /></>,
    // Broadcast arcs — a reachability probe, distinct from Federation's graph.
    network: <><path d="M4.5 9.5a11 11 0 0 1 15 0" /><path d="M7.5 12.8a7 7 0 0 1 9 0" /><path d="M10.3 16a3 3 0 0 1 3.4 0" /><path d="M12 19.2h.01" /></>,
    supercred: <><path d="M7 10V7a5 5 0 0 1 10 0v3" /><rect x="5" y="10" width="14" height="10" rx="2" /><path d="M12 14v2" /></>,
    fleet: <><rect x="3" y="5" width="7" height="6" rx="1" /><rect x="14" y="5" width="7" height="6" rx="1" /><rect x="8.5" y="14" width="7" height="6" rx="1" /><path d="M6.5 11v2h5M17.5 11v2h-5" /></>,
    topology: <><circle cx="6" cy="6" r="2" /><circle cx="18" cy="6" r="2" /><circle cx="12" cy="18" r="2" /><path d="m8 7 3 9M16 7l-3 9M8 6h8" /></>,
    // Painter's palette with paint wells — the only organic blob in the set, so
    // it stays legible against the grids and shields around it.
    designSystem: <><path d="M12 3a9 9 0 0 0 0 18 1.6 1.6 0 0 0 1.6-1.6c0-.42-.16-.8-.42-1.08a1.6 1.6 0 0 1 1.18-2.7h1.9A4.74 4.74 0 0 0 21 10.9C21 6.54 16.97 3 12 3Z" /><circle cx="7.5" cy="12.5" r="1.15" /><circle cx="9.5" cy="8.5" r="1.15" /><circle cx="14" cy="7.5" r="1.15" /></>,
    settings: <><circle cx="12" cy="12" r="3" /><path d="M19 12a7 7 0 0 0-.1-1.1l2-1.6-2-3.4-2.4 1a7 7 0 0 0-1.9-1.1L14.3 3h-4l-.3 2.8a7 7 0 0 0-1.9 1.1l-2.4-1-2 3.4 2 1.6A7 7 0 0 0 5 12c0 .4 0 .8.1 1.1l-2 1.6 2 3.4 2.4-1a7 7 0 0 0 1.9 1.1l.3 2.8h4l.3-2.8a7 7 0 0 0 1.9-1.1l2.4 1 2-3.4-2-1.6c.1-.3.1-.7.1-1.1Z" /></>,
  }
  return <svg aria-hidden="true" className="sl-sidebar__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">{paths[kind]}</svg>
}

export const NAV: NavItem[] = [
  { to: '/discovery', label: 'Discovery', section: 'Workspace', icon: 'discovery' },
  { to: '/agents', label: 'Agents', section: 'Workspace', icon: 'agents' },
  { to: '/compliance', label: 'Compliance', section: 'Governance', icon: 'compliance', end: true },
  { to: '/compliance/policies', label: 'Policy Compliance', section: 'Governance', icon: 'policies' },
  { to: '/compliance/posture', label: 'Agent Posture', section: 'Governance', icon: 'posture' },
  { to: '/compliance/risk', label: 'Risk Exposure', section: 'Governance', icon: 'risk' },
  { to: '/audit', label: 'Audit Trail', section: 'Governance', icon: 'audit' },
  { to: '/cryptography', label: 'Cryptography', section: 'Governance', icon: 'crypto', superadminOnly: true },
  { to: '/credential-inventory', label: 'Credential Inventory', section: 'Governance', icon: 'credentials', superadminOnly: true },
  { to: '/federated-services', label: 'Federated Services', section: 'Governance', icon: 'federation', superadminOnly: true },
  { to: '/collusion-access', label: 'Collusion & Access', section: 'Governance', icon: 'access', superadminOnly: true },
  { to: '/rbac-analysis', label: 'RBAC Analysis', section: 'Governance', icon: 'rbacAnalysis', superadminOnly: true },
  { to: '/rbac-explorer', label: 'RBAC Explorer', section: 'Governance', icon: 'rbacExplorer', superadminOnly: true },
  { to: '/network-tests', label: 'Network Tests', section: 'Governance', icon: 'network', superadminOnly: true },
  { to: '/supercred', label: 'SuperCredential Demo', section: 'Governance', icon: 'supercred', superadminOnly: true },
  { to: '/fleet', label: 'Fleet Demo', section: 'Governance', icon: 'fleet', superadminOnly: true },
  { to: '/agent-trust-topology', label: 'Agent Trust Topology', section: 'Governance', icon: 'topology' },
  { to: '/design-system', label: 'Design System', section: 'Configuration', icon: 'designSystem', superadminOnly: true },
  { to: '/settings', label: 'Settings', section: 'Configuration', icon: 'settings' },
]

// Exported so the quick-search width budget in
// styles/sidebarQuickSearchLayout.test.ts is computed against the real rail
// width rather than a copy of it that can drift.
export const EXPANDED_WIDTH = 268
const COLLAPSED_WIDTH = 64

// Collapsed/expanded is a per-browser display preference, so it lives in
// localStorage alongside the superadmin flag (see auth/superadmin.ts). Reads and
// writes are guarded: Node's inert built-in localStorage and private-mode
// browsers both throw, and neither is a reason to break the nav.
export const SIDEBAR_COLLAPSED_STORAGE_KEY = 'signalloom.sidebar.collapsed'

function readSidebarCollapsed(): boolean {
  try {
    return localStorage.getItem(SIDEBAR_COLLAPSED_STORAGE_KEY) === 'true'
  } catch {
    // Storage unavailable — default to the expanded, fully-labelled nav.
    return false
  }
}

function writeSidebarCollapsed(on: boolean): void {
  try {
    localStorage.setItem(SIDEBAR_COLLAPSED_STORAGE_KEY, on ? 'true' : 'false')
  } catch {
    /* ignore — storage unavailable; the in-memory React state still holds */
  }
}

export default function Sidebar() {
  const { user, logout, getAccessTokenSilently } = useAuth0()
  const { failingControls, setHelpOpen, superadmin, setSuperadmin } = useAppContext()
  const navigate = useNavigate()
  const location = useLocation()
  const [tenant, setTenant] = useState<TenantSettingsResponse | null>(null)
  const [needsTriage, setNeedsTriage] = useState<number | null>(null)
  const [hoveredNav, setHoveredNav] = useState<number | null>(null)
  const [query, setQuery] = useState('')
  const [collapsed, setCollapsed] = useState(readSidebarCollapsed)
  const [pendingSearchFocus, setPendingSearchFocus] = useState(false)
  // `to` is the row the highlight is currently sitting on. Carrying it in the
  // state — rather than deriving it twice — is what makes "the pill and the
  // --active link agree" a single fact instead of two that can drift.
  const [selectionBox, setSelectionBox] = useState<{ to: string; top: number; height: number } | null>(null)
  const navRef = useRef<HTMLDivElement>(null)
  const itemRefs = useRef<Record<string, HTMLAnchorElement | null>>({})
  const searchRef = useRef<HTMLInputElement>(null)

  const canSuperadmin = isSuperadminEligible(user)
  const showSuperadminNav = canSuperadmin && superadmin
  const navItems = NAV.filter(({ superadminOnly }) => !superadminOnly)
  const superadminItems = NAV.filter(({ superadminOnly }) => superadminOnly)
  const normalizedQuery = query.trim().toLowerCase()
  const matchesQuery = ({ label }: NavItem) => !normalizedQuery || label.toLowerCase().includes(normalizedQuery)
  const visibleNavItems = navItems.filter(matchesQuery)
  const visibleSuperadminItems = superadminItems.filter(matchesQuery)
  // A heading, and the rule above it, are labels for the items beneath them —
  // with nothing beneath, they are furniture announcing an empty room. The
  // Workspace/Governance/Configuration headings already derive from
  // visibleNavItems; the superadmin block did not, so it kept printing its
  // divider and title over nothing.
  const hasVisibleSuperadminItems = showSuperadminNav && visibleSuperadminItems.length > 0
  const hasNoMatches = normalizedQuery !== '' && visibleNavItems.length === 0 && !hasVisibleSuperadminItems

  function applyCollapsed(next: boolean) {
    setCollapsed(next)
    writeSidebarCollapsed(next)
    // Collapsing hides the search box, so a live filter would silently shrink
    // the rail with no visible way to undo it.
    if (next) setQuery('')
  }

  function clearSearch() {
    setQuery('')
    searchRef.current?.focus()
  }

  // Escape is handled on the input itself: the window-level handler
  // deliberately ignores events originating in form fields.
  function handleSearchKeyDown(event: React.KeyboardEvent<HTMLInputElement>) {
    if (event.key !== 'Escape') return
    event.preventDefault()
    if (query) setQuery('')
    else event.currentTarget.blur()
  }

  useLayoutEffect(() => {
    const container = navRef.current
    const activeItem = NAV.find(({ to, end }) => end ? location.pathname === to : location.pathname === to || location.pathname.startsWith(`${to}/`))
    const targetTo = (hoveredNav === null ? activeItem : NAV[hoveredNav])?.to
    const target = targetTo ? itemRefs.current[targetTo] : null
    // No row to sit on: the active route is off-nav, filtered out of the rail,
    // or behind the superadmin flag. Withdrawing the highlight is the whole
    // fix — bailing out early instead left it parked on the row it was last
    // measured against, so that row stayed lit while the newly-active one lit
    // up too. Two selected rows, which is what Andy saw.
    if (!container || !target || !targetTo) {
      setSelectionBox(null)
      return
    }
    const containerRect = container.getBoundingClientRect()
    const targetRect = target.getBoundingClientRect()
    // `.sl-sidebar__nav` is the scroll container *and* the containing block, so
    // the pill scrolls with the rows and its `top` is in content coordinates.
    // The rect delta is in viewport coordinates: without adding the scroll
    // offset back, a rail scrolled far enough to reach the superadmin block
    // seats the pill a screenful above the row it belongs to — over whichever
    // row happens to be there.
    const top = targetRect.top - containerRect.top + container.scrollTop
    setSelectionBox({ to: targetTo, top, height: targetRect.height })
    // The rail's geometry moves under the highlight for more reasons than the
    // route changing: filtering removes rows above it, and the superadmin flag
    // adds or removes a whole block. Both have to re-measure.
  }, [hoveredNav, location.pathname, collapsed, normalizedQuery, showSuperadminNav])

  useEffect(() => {
    let canceled = false
    ;(async () => {
      try {
        const token = await getAccessTokenSilently()
        const result = await api.settings(token)
        if (!canceled) setTenant(result)
      } catch {
        // Fail open — a broken tenant-card fetch must not block the nav.
      }
    })()
    return () => { canceled = true }
  }, [getAccessTokenSilently])

  useEffect(() => {
    let canceled = false
    ;(async () => {
      try {
        const token = await getAccessTokenSilently()
        const result = await api.nhi.discovered(token)
        if (!canceled) setNeedsTriage(result.summary.needs_triage)
      } catch {
        // Fail open — a broken discovery-count fetch must not block the nav.
      }
    })()
    return () => { canceled = true }
  }, [getAccessTokenSilently])

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.metaKey || e.ctrlKey || e.altKey) return
      const target = e.target as HTMLElement | null
      const tag = target?.tagName
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target?.isContentEditable) return

      if (e.key === '/') {
        e.preventDefault()
        // The search box is unmounted while collapsed — expand first, then
        // focus it once it exists, rather than leaving "/" as a dead key.
        if (collapsed) {
          applyCollapsed(false)
          setPendingSearchFocus(true)
        } else {
          searchRef.current?.focus()
        }
        return
      }

      const idx = Number(e.key) - 1
      if (Number.isInteger(idx) && idx >= 0 && idx < navItems.length) {
        navigate(navItems[idx].to)
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
    // No dependency array: the handler closes over `collapsed` and over
    // `navItems`, which is rebuilt every render anyway, so this listener always
    // re-registered per render. Being explicit about it beats a stale closure.
  })

  useEffect(() => {
    if (!pendingSearchFocus || collapsed) return
    searchRef.current?.focus()
    setPendingSearchFocus(false)
  }, [pendingSearchFocus, collapsed])

  // Every row in the rail — main block and superadmin block alike — is
  // rendered here. The superadmin block used to be a second copy of this JSX,
  // and the copy had drifted: it registered no `itemRefs` entry and no hover
  // handlers, so the moving selection highlight could neither find a
  // superadmin row nor follow the pointer over one. A duplicated render block
  // that has to be kept in sync is the defect behind the defect.
  function renderNavLink({ to, label, end, icon, superadminOnly }: NavItem) {
    const i = NAV.findIndex((item) => item.to === to)
    // The digit keys bind `navItems`, which excludes superadmin entries, so a
    // badge on one would advertise a shortcut that does not exist.
    const showShortcut = !collapsed && !superadminOnly && hoveredNav === i && i < 9
    return (
      <NavLink
        key={to}
        to={to}
        end={end}
        title={collapsed ? label : undefined}
        className={({ isActive }) => `sl-sidebar__link${isActive ? ' sl-sidebar__link--active' : ''}`}
        ref={(element) => { itemRefs.current[to] = element }}
        onMouseEnter={() => setHoveredNav(i)}
        onFocus={() => setHoveredNav(i)}
        onMouseLeave={() => setHoveredNav(null)}
      >
        <NavIcon kind={icon} />
        {/* Collapsed keeps the label in the a11y tree, not on screen. */}
        <span className={collapsed ? 'sr-only' : 'sl-sidebar__link-label'}>{label}</span>
        {showShortcut && <kbd aria-hidden="true" className="sl-sidebar__shortcut">{i + 1}</kbd>}
        {!collapsed && label === 'Compliance' && failingControls > 0 && (
          <span
            aria-hidden="true"
            style={{
              background: 'var(--error)',
              color: 'var(--on-accent)',
              borderRadius: 99,
              fontSize: 10,
              fontWeight: 700,
              padding: '1px 6px',
              minWidth: 18,
              textAlign: 'center',
            }}>
            {failingControls > 99 ? '99+' : failingControls}
          </span>
        )}
        {!collapsed && label === 'Agents' && tenant && tenant.agent_count > 0 && (
          <span
            aria-hidden="true"
            style={{
              background: 'var(--border)',
              color: 'var(--muted)',
              borderRadius: 99,
              fontSize: 10,
              fontWeight: 700,
              padding: '1px 6px',
              minWidth: 18,
              textAlign: 'center',
            }}>
            {tenant.agent_count > 99 ? '99+' : tenant.agent_count}
          </span>
        )}
        {!collapsed && label === 'Discovery' && needsTriage !== null && needsTriage > 0 && (
          <span
            aria-hidden="true"
            title={`${needsTriage} discovered account${needsTriage === 1 ? '' : 's'} need triage`}
            style={{
              background: 'var(--error)',
              color: 'var(--on-accent)',
              borderRadius: 99,
              fontSize: 10,
              fontWeight: 700,
              padding: '1px 6px',
              minWidth: 18,
              textAlign: 'center',
            }}>
            {needsTriage > 99 ? '99+' : needsTriage}
          </span>
        )}
      </NavLink>
    )
  }

  return (
    <>
      <HelpModal />
      <ApiKeyRevealModal />
      <nav aria-label="Primary navigation" className={`sl-sidebar${collapsed ? ' sl-sidebar--collapsed' : ''}`} style={{
        width: collapsed ? COLLAPSED_WIDTH : EXPANDED_WIDTH,
        minWidth: collapsed ? COLLAPSED_WIDTH : EXPANDED_WIDTH,
        height: '100vh',
        background: 'var(--surface)',
        borderRight: '1px solid var(--border)',
        display: 'flex',
        flexDirection: 'column',
        position: 'sticky',
        top: 0,
        overflow: 'hidden',
        flexShrink: 0,
      }}>
        {/* Workspace identity */}
        <div className="sl-sidebar__workspace">
          <button
            onClick={() => navigate('/agents')}
            className="sl-sidebar__workspace-button"
            title={collapsed ? (tenant?.org_name || 'Signal Loom') : undefined}
          >
            {/* The real woven-diamond mark, transparent-keyed so it carries
              * across all three themes. Decorative: it sits beside the
              * workspace title (or its sr-only twin when collapsed), and a
              * named image here would give the button a second accessible
              * name. The asset is square — `contain` keeps it that way even if
              * the flex row squeezes the box. */}
            <img
              src="/brand/signal-loom-logo.png"
              alt=""
              aria-hidden="true"
              width={32}
              height={32}
              className="sl-sidebar__workspace-logo"
              style={{ width: 32, height: 32, objectFit: 'contain', flexShrink: 0, display: 'block' }}
            />
            {collapsed ? (
              <span className="sr-only">{tenant?.org_name || 'Signal Loom'}</span>
            ) : (
              <>
                <div className="sl-sidebar__workspace-copy">
                  <div className="sl-sidebar__workspace-title">{tenant?.org_name || 'Signal Loom'}</div>
                  <div className="sl-sidebar__workspace-subtitle">Agent governance workspace</div>
                </div>
                <span aria-hidden="true" className="sl-sidebar__workspace-chevron">↕</span>
              </>
            )}
          </button>
          <button
            type="button"
            data-testid="sidebar-collapse-toggle"
            className="sl-sidebar__collapse-toggle"
            aria-expanded={!collapsed}
            aria-controls="sl-sidebar-nav"
            aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
            title={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
            onClick={() => applyCollapsed(!collapsed)}
          >
            {/* A chevron beside a bare vertical stroke reads as "next/previous"
              * far more readily than "collapse this panel" — the stroke has no
              * shape to identify it as an edge of anything. This is the
              * conventional panel glyph instead: a framed rectangle with the
              * rail partitioned off inside it, so the icon depicts the thing it
              * acts on. Only the chevron flips between states, and it always
              * points the way the rail is about to travel — left to close, right
              * to reopen — so the icon states the outcome, not the state. */}
            <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
              <rect x="3" y="4" width="18" height="16" rx="2" />
              <path d="M9 4v16" />
              {collapsed
                ? <path d="m14 9.5 2.5 2.5-2.5 2.5" />
                : <path d="m16.5 9.5-2.5 2.5 2.5 2.5" />}
            </svg>
          </button>
        </div>

        {!collapsed && (
          <label className="sl-sidebar__quick-search">
            <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="11" cy="11" r="7" /><path d="m20 20-4-4" /></svg>
            <span className="sr-only">Quick search navigation</span>
            <input
              ref={searchRef}
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              onKeyDown={handleSearchKeyDown}
              placeholder="Quick search"
            />
            {query ? (
              <button
                type="button"
                data-testid="sidebar-search-clear"
                className="sl-sidebar__search-clear"
                aria-label="Clear search"
                title="Clear search"
                onClick={clearSearch}
              >
                <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><path d="m6 6 12 12M18 6 6 18" /></svg>
              </button>
            ) : (
              <kbd aria-hidden="true">/</kbd>
            )}
          </label>
        )}

        {/* Nav links */}
        <div ref={navRef} id="sl-sidebar-nav" className="sl-sidebar__nav" onMouseLeave={() => setHoveredNav(null)}>
          {selectionBox && (
            <span
              aria-hidden="true"
              data-nav-to={selectionBox.to}
              className="sl-sidebar__selection"
              style={{ top: selectionBox.top, height: selectionBox.height }}
            />
          )}
          {visibleNavItems.map((item, visibleIndex) => {
            // Previous *visible* sibling, so a heading is emitted only where a
            // section actually starts in the filtered list.
            const previous = visibleNavItems[visibleIndex - 1]
            return (
              <div key={item.to}>
                {!collapsed && (!previous || previous.section !== item.section) && (
                  <div className="sl-sidebar__section-label">{item.section}</div>
                )}
                {renderNavLink(item)}
              </div>
            )
          })}

          {/* Superadmin-only nav block. Gated on there being something to show:
            * filtering used to leave the rule and the "Superadmin" title
            * stranded above nothing. */}
          {hasVisibleSuperadminItems && (
            <>
              <hr style={{ border: 'none', borderTop: '1px solid var(--border)', margin: collapsed ? '8px 6px' : '8px 14px' }} />
              {!collapsed && (
                <div style={{ fontSize: 10, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.08em', padding: '4px 14px 2px' }}>
                  Superadmin
                </div>
              )}
              {visibleSuperadminItems.map((item) => renderNavLink(item))}
            </>
          )}

          {/* Filtering everything away leaves a blank rail, which reads as
            * broken rather than filtered and offers no way out. role="status"
            * so the result is announced, not merely drawn — the filter is
            * driven from a text box the user is already focused in, and a
            * silent change of nothing to nothing is the one case a screen
            * reader would otherwise miss. */}
          {hasNoMatches && (
            <p className="sl-sidebar__empty" role="status" data-testid="sidebar-no-matches">
              No navigation matches <strong>{query.trim()}</strong>.
              <br />
              Press Escape to clear the search.
            </p>
          )}
        </div>

        {/* Bottom: help + superadmin + user */}
        <div style={{ padding: collapsed ? '8px 4px 16px' : '8px 8px 16px', borderTop: '1px solid var(--border)' }}>
          <button
            onClick={() => setHelpOpen(true)}
            aria-label="Open help and support"
            title={collapsed ? 'Help & Support' : undefined}
            style={{
              width: '100%',
              display: 'flex',
              alignItems: 'center',
              justifyContent: collapsed ? 'center' : 'flex-start',
              padding: collapsed ? '9px 0' : '9px 14px',
              borderRadius: 8,
              background: 'none',
              border: 'none',
              color: 'var(--muted)',
              fontSize: 14,
              cursor: 'pointer',
              fontFamily: 'inherit',
              transition: 'color 0.12s',
              marginBottom: 4,
            }}
            onMouseEnter={(e) => (e.currentTarget.style.color = 'var(--text)')}
            onMouseLeave={(e) => (e.currentTarget.style.color = 'var(--muted)')}
          >
            {collapsed ? (
              <svg aria-hidden="true" className="sl-sidebar__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                <circle cx="12" cy="12" r="9" /><path d="M9.6 9.4a2.5 2.5 0 0 1 4.8.9c0 1.7-2.4 2.2-2.4 3.7" /><path d="M12 17.3h.01" />
              </svg>
            ) : 'Help & Support'}
          </button>

          {canSuperadmin && (
            <button
              data-testid="superadmin-toggle"
              onClick={() => setSuperadmin(!superadmin)}
              aria-label="Toggle superadmin navigation"
              aria-pressed={superadmin}
              title="Show or hide the superadmin-only sections"
              style={{
                width: '100%',
                display: 'flex',
                alignItems: 'center',
                justifyContent: collapsed ? 'center' : 'space-between',
                gap: 8,
                padding: collapsed ? '9px 0' : '9px 14px',
                borderRadius: 8,
                background: 'none',
                border: 'none',
                color: 'var(--muted)',
                fontSize: 14,
                cursor: 'pointer',
                fontFamily: 'inherit',
                transition: 'color 0.12s',
                marginBottom: 4,
              }}
              onMouseEnter={(e) => (e.currentTarget.style.color = 'var(--text)')}
              onMouseLeave={(e) => (e.currentTarget.style.color = 'var(--muted)')}
            >
              {!collapsed && 'Superadmin'}
              <span style={{
                fontSize: 10,
                fontWeight: 700,
                letterSpacing: '0.08em',
                textTransform: 'uppercase',
                borderRadius: 99,
                padding: '1px 6px',
                color: superadmin ? 'var(--cyan)' : 'var(--muted)',
                background: superadmin ? 'var(--surface2)' : 'transparent',
                border: `1px solid ${superadmin ? 'var(--cyan)' : 'var(--border)'}`,
              }}>
                {superadmin ? 'On' : 'Off'}
              </span>
            </button>
          )}

          <div style={{
            display: 'flex',
            flexDirection: collapsed ? 'column' : 'row',
            alignItems: 'center',
            gap: collapsed ? 4 : 10,
            padding: collapsed ? '6px 0' : '6px 14px',
          }}>
            {user?.picture ? (
              <img
                src={user.picture}
                alt={user.name ?? 'avatar'}
                style={{ width: 28, height: 28, borderRadius: '50%', flexShrink: 0 }}
              />
            ) : (
              <div style={{
                width: 28, height: 28, borderRadius: '50%',
                background: 'var(--violet)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: 12, fontWeight: 700, color: 'var(--on-accent)', flexShrink: 0,
              }}>
                {(user?.name ?? user?.email ?? 'U').charAt(0).toUpperCase()}
              </div>
            )}
            {!collapsed && (
              <div style={{ flex: 1, overflow: 'hidden', minWidth: 0 }}>
                <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--text)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {user?.name ?? user?.email ?? 'User'}
                </div>
              </div>
            )}
            <button
              onClick={() => logout({ logoutParams: { returnTo: window.location.origin } })}
              aria-label="Sign out"
              style={{ background: 'none', border: 'none', color: 'var(--muted)', fontSize: 11, cursor: 'pointer', flexShrink: 0, padding: '2px 4px' }}
              title="Sign out"
            >
              ↪
            </button>
          </div>
        </div>
      </nav>
    </>
  )
}
