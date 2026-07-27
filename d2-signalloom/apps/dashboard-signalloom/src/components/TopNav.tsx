import { NavLink, useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { useAppContext } from '../App'
import HelpModal from './HelpModal'

const NAV_LINKS = [
  { to: '/agents', label: 'Agents' },
  { to: '/compliance', label: 'Compliance' },
  { to: '/audit', label: 'Audit Trail' },
  { to: '/settings', label: 'Settings' },
]

export default function TopNav() {
  const { user, logout } = useAuth0()
  const { failingControls, setHelpOpen } = useAppContext()
  const navigate = useNavigate()

  return (
    <>
      <HelpModal />
      <nav style={{
        height: 60,
        background: 'var(--surface)',
        borderBottom: '1px solid var(--border)',
        display: 'flex',
        alignItems: 'center',
        padding: '0 32px',
        gap: 0,
        position: 'sticky',
        top: 0,
        zIndex: 100,
        flexShrink: 0,
      }}>
        {/* Logo */}
        <button
          onClick={() => navigate('/agents')}
          style={{ background: 'none', border: 'none', display: 'flex', alignItems: 'center', gap: 10, marginRight: 32, padding: 0 }}
        >
          <svg width="28" height="28" viewBox="0 0 28 28" fill="none">
            <rect width="28" height="28" rx="6" fill="#06d6a0" fillOpacity="0.15" />
            <path d="M6 14 L14 6 L22 14 L14 22 Z" stroke="#06d6a0" strokeWidth="2" fill="none" strokeLinejoin="round" />
            <circle cx="14" cy="14" r="3" fill="#06d6a0" />
          </svg>
          <span style={{ fontSize: 15, fontWeight: 700, color: 'var(--text)', letterSpacing: '-0.02em' }}>
            Signal Loom
          </span>
        </button>

        {/* Nav links */}
        <div style={{ display: 'flex', gap: 4, flex: 1 }}>
          {NAV_LINKS.map(({ to, label }) => (
            <NavLink
              key={to}
              to={to}
              style={({ isActive }) => ({
                padding: '6px 14px',
                borderRadius: 6,
                fontSize: 13,
                fontWeight: 500,
                color: isActive ? 'var(--cyan)' : 'var(--muted)',
                background: isActive ? 'rgba(6,214,160,0.08)' : 'transparent',
                transition: 'color 0.15s, background 0.15s',
                display: 'flex',
                alignItems: 'center',
                gap: 6,
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

        {/* Right side */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <button
            className="btn btn-secondary"
            onClick={() => setHelpOpen(true)}
            style={{ fontSize: 12, padding: '5px 12px' }}
          >
            Help
          </button>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            {user?.picture ? (
              <img
                src={user.picture}
                alt={user.name ?? 'avatar'}
                style={{ width: 30, height: 30, borderRadius: '50%', border: '2px solid var(--border)' }}
              />
            ) : (
              <div style={{ width: 30, height: 30, borderRadius: '50%', background: 'var(--violet)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 700, color: '#fff' }}>
                {(user?.name ?? user?.email ?? 'U').charAt(0).toUpperCase()}
              </div>
            )}
            <button
              className="btn"
              onClick={() => logout({ logoutParams: { returnTo: window.location.origin } })}
              style={{ fontSize: 12, padding: '5px 10px', background: 'none', border: '1px solid var(--border)', color: 'var(--muted)', borderRadius: 6 }}
            >
              Sign out
            </button>
          </div>
        </div>
      </nav>
    </>
  )
}
