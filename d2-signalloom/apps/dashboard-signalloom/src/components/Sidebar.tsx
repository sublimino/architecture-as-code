import { NavLink, useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { useAppContext } from '../App'
import { isSuperadminEligible } from '../auth/superadmin'
import HelpModal from './HelpModal'
import ApiKeyRevealModal from './ApiKeyRevealModal'

// `superadminOnly` hides a link from the nav when superadmin mode is off. This
// is VISIBILITY ONLY, not authorization — the routes stay registered in App.tsx
// and remain reachable by direct URL.
interface NavItem {
  to: string
  label: string
  superadminOnly?: boolean
}

const NAV: NavItem[] = [
  { to: '/agents', label: 'Agents' },
  { to: '/compliance', label: 'Compliance' },
  { to: '/audit', label: 'Audit Trail' },
  { to: '/cryptography', label: 'Cryptography', superadminOnly: true },
  { to: '/federated-services', label: 'Federated Services', superadminOnly: true },
  { to: '/collusion-access', label: 'Collusion & Access', superadminOnly: true },
  { to: '/rbac-analysis', label: 'RBAC Analysis', superadminOnly: true },
  { to: '/rbac-explorer', label: 'RBAC Explorer', superadminOnly: true },
  { to: '/supercred', label: 'SuperCred' },
  { to: '/settings', label: 'Settings' },
]

export default function Sidebar() {
  const { user, logout } = useAuth0()
  const { failingControls, setHelpOpen, superadmin, setSuperadmin } = useAppContext()
  const navigate = useNavigate()

  // The identity gate wins over the stored preference: a stale
  // signalloom.superadmin=true for a non-eligible user reveals nothing.
  const canSuperadmin = isSuperadminEligible(user)
  const showSuperadminNav = canSuperadmin && superadmin
  const navItems = NAV.filter(({ superadminOnly }) => !superadminOnly || showSuperadminNav)

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

        {/* Nav links */}
        <div style={{ flex: 1, padding: '12px 8px', display: 'flex', flexDirection: 'column', gap: 2 }}>
          {navItems.map(({ to, label }) => (
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
            </NavLink>
          ))}
        </div>

        {/* Bottom: help + user */}
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

          {/* Superadmin visibility toggle — demo user only, see auth/superadmin.ts */}
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
