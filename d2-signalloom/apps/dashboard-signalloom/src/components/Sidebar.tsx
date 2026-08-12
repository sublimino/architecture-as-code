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
  | 'topology' | 'settings'

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
  { to: '/settings', label: 'Settings', section: 'Configuration', icon: 'settings' },
]

const EXPANDED_WIDTH = 268
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
  const [selectionBox, setSelectionBox] = useState<{ top: number; height: number } | null>(null)
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
    const target = itemRefs.current[hoveredNav === null ? activeItem?.to ?? '' : NAV[hoveredNav]?.to]
    if (!container || !target) return
    const containerRect = container.getBoundingClientRect()
    const targetRect = target.getBoundingClientRect()
    setSelectionBox({ top: targetRect.top - containerRect.top, height: targetRect.height })
  }, [hoveredNav, location.pathname, collapsed])

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
            <svg aria-hidden="true" width="32" height="32" viewBox="0 0 32 32" fill="none">
              <rect width="32" height="32" rx="8" fill="var(--cyan)" fillOpacity="0.12" />
              <path d="M7 16 L16 7 L25 16 L16 25 Z" stroke="var(--cyan)" strokeWidth="1.75" fill="none" strokeLinejoin="round" />
              <circle cx="16" cy="16" r="3.5" fill="var(--cyan)" fillOpacity="0.35" />
              <circle cx="16" cy="16" r="1.75" fill="var(--cyan)" />
            </svg>
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
            <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
              {collapsed
                ? <><path d="m9 6 6 6-6 6" /><path d="M18 5v14" /></>
                : <><path d="m15 6-6 6 6 6" /><path d="M6 5v14" /></>}
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
          {selectionBox && <span aria-hidden="true" className="sl-sidebar__selection" style={{ top: selectionBox.top, height: selectionBox.height }} />}
          {visibleNavItems.map(({ to, label, end, section, icon }) => {
            const i = NAV.findIndex((item) => item.to === to)
            const previous = visibleNavItems[visibleNavItems.indexOf(visibleNavItems.find((item) => item.to === to)!)-1]
            return (
            <div key={to}>
            {!collapsed && (!previous || previous.section !== section) && (
              <div className="sl-sidebar__section-label">{section}</div>
            )}
            <NavLink
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
              {!collapsed && hoveredNav === i && i < 9 && <kbd aria-hidden="true" className="sl-sidebar__shortcut">{i + 1}</kbd>}
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
            </div>
          )})}

          {/* Superadmin-only nav block */}
          {showSuperadminNav && (
            <>
              <hr style={{ border: 'none', borderTop: '1px solid var(--border)', margin: collapsed ? '8px 6px' : '8px 14px' }} />
              {!collapsed && (
                <div style={{ fontSize: 10, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.08em', padding: '4px 14px 2px' }}>
                  Superadmin
                </div>
              )}
              {visibleSuperadminItems.map(({ to, label, icon }) => (
                <NavLink
                  key={to}
                  to={to}
                  title={collapsed ? label : undefined}
                  className={({ isActive }) => `sl-sidebar__link${isActive ? ' sl-sidebar__link--active' : ''}`}
                >
                  <NavIcon kind={icon} />
                  <span className={collapsed ? 'sr-only' : 'sl-sidebar__link-label'}>{label}</span>
                </NavLink>
              ))}
            </>
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
