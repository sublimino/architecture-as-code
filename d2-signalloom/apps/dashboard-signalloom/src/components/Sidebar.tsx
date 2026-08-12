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

interface NavItem {
  to: string
  label: string
  section: 'Workspace' | 'Governance' | 'Configuration'
  icon: IconKind
  end?: boolean
  superadminOnly?: boolean
}

type IconKind = 'discovery' | 'agents' | 'compliance' | 'audit' | 'crypto' | 'credentials' | 'federation' | 'access' | 'rbac' | 'network' | 'supercred' | 'fleet' | 'topology' | 'settings'

function NavIcon({ kind }: { kind: IconKind }) {
  const paths: Record<IconKind, React.ReactNode> = {
    discovery: <><circle cx="11" cy="11" r="6" /><path d="m16 16 4 4M11 8v6M8 11h6" /></>,
    agents: <><rect x="4" y="4" width="16" height="16" rx="3" /><path d="M8 12h8M12 8v8" /></>,
    compliance: <><path d="M12 3 5 6v5c0 5 3 8 7 10 4-2 7-5 7-10V6l-7-3Z" /><path d="m9 12 2 2 4-4" /></>,
    audit: <><path d="M5 4h14v16H5z" /><path d="M8 8h8M8 12h8M8 16h5" /></>,
    crypto: <><path d="M12 3 4 7v5c0 5 3.4 8 8 9 4.6-1 8-4 8-9V7l-8-4Z" /><path d="M9 12h6M12 9v6" /></>,
    credentials: <><circle cx="8" cy="15" r="3" /><path d="m10 13 7-7 2 2-7 7M14 9l2 2" /></>,
    federation: <><circle cx="7" cy="12" r="3" /><circle cx="17" cy="7" r="3" /><circle cx="17" cy="17" r="3" /><path d="m10 11 4-3M10 13l4 3" /></>,
    access: <><circle cx="12" cy="8" r="3" /><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6M19 8v4M17 10h4" /></>,
    rbac: <><path d="M4 5h16v14H4z" /><path d="M8 9h8M8 13h5M8 17h7" /></>,
    network: <><circle cx="5" cy="12" r="2" /><circle cx="19" cy="5" r="2" /><circle cx="19" cy="19" r="2" /><path d="m7 11 10-5M7 13l10 5" /></>,
    supercred: <><path d="M7 10V7a5 5 0 0 1 10 0v3" /><rect x="5" y="10" width="14" height="10" rx="2" /><path d="M12 14v2" /></>,
    fleet: <><rect x="3" y="5" width="7" height="6" rx="1" /><rect x="14" y="5" width="7" height="6" rx="1" /><rect x="8.5" y="14" width="7" height="6" rx="1" /><path d="M6.5 11v2h5M17.5 11v2h-5" /></>,
    topology: <><circle cx="6" cy="6" r="2" /><circle cx="18" cy="6" r="2" /><circle cx="12" cy="18" r="2" /><path d="m8 7 3 9M16 7l-3 9M8 6h8" /></>,
    settings: <><circle cx="12" cy="12" r="3" /><path d="M19 12a7 7 0 0 0-.1-1.1l2-1.6-2-3.4-2.4 1a7 7 0 0 0-1.9-1.1L14.3 3h-4l-.3 2.8a7 7 0 0 0-1.9 1.1l-2.4-1-2 3.4 2 1.6A7 7 0 0 0 5 12c0 .4 0 .8.1 1.1l-2 1.6 2 3.4 2.4-1a7 7 0 0 0 1.9 1.1l.3 2.8h4l.3-2.8a7 7 0 0 0 1.9-1.1l2.4 1 2-3.4-2-1.6c.1-.3.1-.7.1-1.1Z" /></>,
  }
  return <svg aria-hidden="true" className="sl-sidebar__icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">{paths[kind]}</svg>
}

const NAV: NavItem[] = [
  { to: '/discovery', label: 'Discovery', section: 'Workspace', icon: 'discovery' },
  { to: '/agents', label: 'Agents', section: 'Workspace', icon: 'agents' },
  { to: '/compliance', label: 'Compliance', section: 'Governance', icon: 'compliance', end: true },
  { to: '/compliance/policies', label: 'Policy Compliance', section: 'Governance', icon: 'compliance' },
  { to: '/compliance/posture', label: 'Agent Posture', section: 'Governance', icon: 'compliance' },
  { to: '/compliance/risk', label: 'Risk Exposure', section: 'Governance', icon: 'compliance' },
  { to: '/audit', label: 'Audit Trail', section: 'Governance', icon: 'audit' },
  { to: '/cryptography', label: 'Cryptography', section: 'Governance', icon: 'crypto', superadminOnly: true },
  { to: '/credential-inventory', label: 'Credential Inventory', section: 'Governance', icon: 'credentials', superadminOnly: true },
  { to: '/federated-services', label: 'Federated Services', section: 'Governance', icon: 'federation', superadminOnly: true },
  { to: '/collusion-access', label: 'Collusion & Access', section: 'Governance', icon: 'access', superadminOnly: true },
  { to: '/rbac-analysis', label: 'RBAC Analysis', section: 'Governance', icon: 'rbac', superadminOnly: true },
  { to: '/rbac-explorer', label: 'RBAC Explorer', section: 'Governance', icon: 'rbac', superadminOnly: true },
  { to: '/network-tests', label: 'Network Tests', section: 'Governance', icon: 'network', superadminOnly: true },
  { to: '/supercred', label: 'SuperCredential Demo', section: 'Governance', icon: 'supercred', superadminOnly: true },
  { to: '/fleet', label: 'Fleet Demo', section: 'Governance', icon: 'fleet', superadminOnly: true },
  { to: '/agent-trust-topology', label: 'Agent Trust Topology', section: 'Governance', icon: 'topology' },
  { to: '/settings', label: 'Settings', section: 'Configuration', icon: 'settings' },
]

export default function Sidebar() {
  const { user, logout, getAccessTokenSilently } = useAuth0()
  const { failingControls, setHelpOpen, superadmin, setSuperadmin } = useAppContext()
  const navigate = useNavigate()
  const location = useLocation()
  const [tenant, setTenant] = useState<TenantSettingsResponse | null>(null)
  const [needsTriage, setNeedsTriage] = useState<number | null>(null)
  const [hoveredNav, setHoveredNav] = useState<number | null>(null)
  const [query, setQuery] = useState('')
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

  useLayoutEffect(() => {
    const container = navRef.current
    const activeItem = NAV.find(({ to, end }) => end ? location.pathname === to : location.pathname === to || location.pathname.startsWith(`${to}/`))
    const target = itemRefs.current[hoveredNav === null ? activeItem?.to ?? '' : NAV[hoveredNav]?.to]
    if (!container || !target) return
    const containerRect = container.getBoundingClientRect()
    const targetRect = target.getBoundingClientRect()
    setSelectionBox({ top: targetRect.top - containerRect.top, height: targetRect.height })
  }, [hoveredNav, location.pathname])

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
        searchRef.current?.focus()
        return
      }

      const idx = Number(e.key) - 1
      if (Number.isInteger(idx) && idx >= 0 && idx < navItems.length) {
        navigate(navItems[idx].to)
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [navigate, navItems])

  return (
    <>
      <HelpModal />
      <ApiKeyRevealModal />
      <nav aria-label="Primary navigation" className="sl-sidebar" style={{
        width: 268,
        minWidth: 268,
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
          >
            <svg aria-hidden="true" width="32" height="32" viewBox="0 0 32 32" fill="none">
              <rect width="32" height="32" rx="8" fill="var(--cyan)" fillOpacity="0.12" />
              <path d="M7 16 L16 7 L25 16 L16 25 Z" stroke="var(--cyan)" strokeWidth="1.75" fill="none" strokeLinejoin="round" />
              <circle cx="16" cy="16" r="3.5" fill="var(--cyan)" fillOpacity="0.35" />
              <circle cx="16" cy="16" r="1.75" fill="var(--cyan)" />
            </svg>
            <div className="sl-sidebar__workspace-copy">
              <div className="sl-sidebar__workspace-title">{tenant?.org_name || 'Signal Loom'}</div>
              <div className="sl-sidebar__workspace-subtitle">Agent governance workspace</div>
            </div>
            <span aria-hidden="true" className="sl-sidebar__workspace-chevron">↕</span>
          </button>
        </div>

        <label className="sl-sidebar__quick-search">
          <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="11" cy="11" r="7" /><path d="m20 20-4-4" /></svg>
          <span className="sr-only">Quick search navigation</span>
          <input ref={searchRef} value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Quick search" />
          <kbd aria-hidden="true">/</kbd>
        </label>

        {/* Nav links */}
        <div ref={navRef} className="sl-sidebar__nav" onMouseLeave={() => setHoveredNav(null)}>
          {selectionBox && <span aria-hidden="true" className="sl-sidebar__selection" style={{ top: selectionBox.top, height: selectionBox.height }} />}
          {visibleNavItems.map(({ to, label, end, section, icon }) => {
            const i = NAV.findIndex((item) => item.to === to)
            const previous = visibleNavItems[visibleNavItems.indexOf(visibleNavItems.find((item) => item.to === to)!)-1]
            return (
            <div key={to}>
            {(!previous || previous.section !== section) && (
              <div className="sl-sidebar__section-label">{section}</div>
            )}
            <NavLink
              to={to}
              end={end}
              className={({ isActive }) => `sl-sidebar__link${isActive ? ' sl-sidebar__link--active' : ''}`}
              ref={(element) => { itemRefs.current[to] = element }}
              onMouseEnter={() => setHoveredNav(i)}
              onFocus={() => setHoveredNav(i)}
              onMouseLeave={() => setHoveredNav(null)}
            >
              <NavIcon kind={icon} />
              <span className="sl-sidebar__link-label">{label}</span>
              {hoveredNav === i && i < 9 && <kbd aria-hidden="true" className="sl-sidebar__shortcut">{i + 1}</kbd>}
              {label === 'Compliance' && failingControls > 0 && (
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
              {label === 'Agents' && tenant && tenant.agent_count > 0 && (
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
              {label === 'Discovery' && needsTriage !== null && needsTriage > 0 && (
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
              <hr style={{ border: 'none', borderTop: '1px solid var(--border)', margin: '8px 14px' }} />
              <div style={{ fontSize: 10, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.08em', padding: '4px 14px 2px' }}>
                Superadmin
              </div>
              {visibleSuperadminItems.map(({ to, label, icon }) => (
                <NavLink
                  key={to}
                  to={to}
                  className={({ isActive }) => `sl-sidebar__link${isActive ? ' sl-sidebar__link--active' : ''}`}
                >
                  <NavIcon kind={icon} />
                  {label}
                </NavLink>
              ))}
            </>
          )}
        </div>

        {/* Bottom: help + superadmin + user */}
        <div style={{ padding: '8px 8px 16px', borderTop: '1px solid var(--border)' }}>
          <button
            onClick={() => setHelpOpen(true)}
            aria-label="Open help and support"
            style={{
              width: '100%',
              display: 'flex',
              alignItems: 'center',
              padding: '9px 14px',
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
            Help & Support
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
                justifyContent: 'space-between',
                gap: 8,
                padding: '9px 14px',
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
              Superadmin
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

          <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '6px 14px' }}>
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
            <div style={{ flex: 1, overflow: 'hidden', minWidth: 0 }}>
              <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--text)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {user?.name ?? user?.email ?? 'User'}
              </div>
            </div>
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
