import { useState, useEffect } from 'react'
import { NavLink, useNavigate } from 'react-router-dom'
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
  superadminOnly?: boolean
}

const NAV: NavItem[] = [
  { to: '/discovery', label: 'Discovery' },
  { to: '/agents', label: 'Agents' },
  { to: '/compliance', label: 'Compliance' },
  { to: '/compliance/policies', label: 'Policy Compliance' },
  { to: '/compliance/posture', label: 'Agent Posture' },
  { to: '/compliance/risk', label: 'Risk Exposure' },
  { to: '/audit', label: 'Audit Trail' },
  { to: '/cryptography', label: 'Cryptography', superadminOnly: true },
  { to: '/federated-services', label: 'Federated Services', superadminOnly: true },
  { to: '/collusion-access', label: 'Collusion & Access', superadminOnly: true },
  { to: '/rbac-analysis', label: 'RBAC Analysis', superadminOnly: true },
  { to: '/rbac-explorer', label: 'RBAC Explorer', superadminOnly: true },
  { to: '/network-tests', label: 'Network Tests', superadminOnly: true },
  { to: '/supercred', label: 'SuperCred' },
  { to: '/settings', label: 'Settings' },
]

export default function Sidebar() {
  const { user, logout, getAccessTokenSilently } = useAuth0()
  const { failingControls, setHelpOpen, superadmin, setSuperadmin } = useAppContext()
  const navigate = useNavigate()
  const [tenant, setTenant] = useState<TenantSettingsResponse | null>(null)
  const [needsTriage, setNeedsTriage] = useState<number | null>(null)
  const [hoveredNav, setHoveredNav] = useState<number | null>(null)

  const canSuperadmin = isSuperadminEligible(user)
  const showSuperadminNav = canSuperadmin && superadmin
  const navItems = NAV.filter(({ superadminOnly }) => !superadminOnly)
  const superadminItems = NAV.filter(({ superadminOnly }) => superadminOnly)

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
      <nav style={{
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
        {/* Logo + tenant */}
        <div style={{ padding: '24px 20px 20px', borderBottom: '1px solid var(--border)' }}>
          <button
            onClick={() => navigate('/agents')}
            style={{ background: 'none', border: 'none', display: 'flex', alignItems: 'center', gap: 12, padding: 0, width: '100%', cursor: 'pointer' }}
          >
            <svg width="32" height="32" viewBox="0 0 32 32" fill="none">
              <rect width="32" height="32" rx="8" fill="#06B6D4" fillOpacity="0.12" />
              <path d="M7 16 L16 7 L25 16 L16 25 Z" stroke="#06B6D4" strokeWidth="1.75" fill="none" strokeLinejoin="round" />
              <circle cx="16" cy="16" r="3.5" fill="#06B6D4" fillOpacity="0.35" />
              <circle cx="16" cy="16" r="1.75" fill="#06B6D4" />
            </svg>
            <div style={{ textAlign: 'left' }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--text)', letterSpacing: '0.08em', textTransform: 'uppercase', lineHeight: 1.2 }}>
                Signal Loom
              </div>
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2, lineHeight: 1 }}>
                Customer Portal
              </div>
            </div>
          </button>
        </div>

        {/* Tenant identity card */}
        {tenant && (
          <div style={{ padding: '14px 20px', borderBottom: '1px solid var(--border)' }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {tenant.org_name || 'Unnamed Organization'}
            </div>
          </div>
        )}

        {/* Nav links */}
        <div style={{ flex: 1, padding: '12px 8px', display: 'flex', flexDirection: 'column', gap: 2, overflowY: 'auto' }}>
          {navItems.map(({ to, label }, i) => (
            <NavLink
              key={to}
              to={to}
              onMouseEnter={() => setHoveredNav(i)}
              onMouseLeave={() => setHoveredNav(null)}
              style={({ isActive }) => ({
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                padding: '9px 14px',
                borderRadius: 8,
                fontSize: 14,
                fontWeight: isActive ? 600 : 400,
                color: isActive ? 'var(--cyan)' : 'var(--muted)',
                background: isActive ? 'rgba(6,182,212,0.10)' : 'transparent',
                transition: 'color 0.12s, background 0.12s',
                textDecoration: 'none',
              })}
            >
              <span style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                {label}
                {hoveredNav === i && i < 9 && (
                  <span
                    aria-hidden="true"
                    style={{
                      fontSize: 10,
                      fontWeight: 600,
                      color: 'var(--muted)',
                      background: 'var(--border)',
                      borderRadius: 4,
                      padding: '1px 5px',
                      fontFamily: 'monospace',
                      lineHeight: 1.4,
                    }}
                  >
                    {i + 1}
                  </span>
                )}
              </span>
              {label === 'Compliance' && failingControls > 0 && (
                <span style={{
                  background: 'var(--error)',
                  color: '#fff',
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
                <span style={{
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
                  title={`${needsTriage} discovered account${needsTriage === 1 ? '' : 's'} need triage`}
                  style={{
                    background: 'var(--error)',
                    color: '#fff',
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
          ))}

          {/* Superadmin-only nav block */}
          {showSuperadminNav && (
            <>
              <hr style={{ border: 'none', borderTop: '1px solid var(--border)', margin: '8px 14px' }} />
              <div style={{ fontSize: 10, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.08em', padding: '4px 14px 2px' }}>
                Superadmin
              </div>
              {superadminItems.map(({ to, label }) => (
                <NavLink
                  key={to}
                  to={to}
                  style={({ isActive }) => ({
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    padding: '9px 14px',
                    borderRadius: 8,
                    fontSize: 14,
                    fontWeight: isActive ? 600 : 400,
                    color: isActive ? 'var(--cyan)' : 'var(--muted)',
                    background: isActive ? 'rgba(6,182,212,0.10)' : 'transparent',
                    transition: 'color 0.12s, background 0.12s',
                    textDecoration: 'none',
                  })}
                >
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
                background: superadmin ? 'rgba(6,182,212,0.10)' : 'transparent',
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
                fontSize: 12, fontWeight: 700, color: '#fff', flexShrink: 0,
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
