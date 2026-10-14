import React from 'react'
import { NavLink, useLocation } from 'react-router-dom'

export default function AdminNavTabs(): React.JSX.Element {
  let hasRouter = true
  let pathname = ''
  try {
    const loc = useLocation()
    pathname = loc.pathname
  } catch {
    hasRouter = false
  }

  if (!hasRouter) {
    return (
      <nav
        role="tablist"
        aria-label="Admin Navigation"
        style={{
          display: 'flex',
          gap: 8,
          borderBottom: '1px solid var(--border)',
          marginBottom: 8,
        }}
      >
        <a
          href="/admin/users"
          role="tab"
          id="admin-tab-users"
          data-testid="admin-tab-users"
          style={{
            padding: '8px 16px',
            fontSize: 13,
            fontWeight: 600,
            textDecoration: 'none',
            color: 'var(--teal)',
            borderBottom: '2px solid var(--teal)',
          }}
        >
          User Administration
        </a>
        <a
          href="/admin/features"
          role="tab"
          id="admin-tab-features"
          data-testid="admin-tab-features"
          style={{
            padding: '8px 16px',
            fontSize: 13,
            fontWeight: 600,
            textDecoration: 'none',
            color: 'var(--muted)',
            borderBottom: '2px solid transparent',
          }}
        >
          Feature Flags
        </a>
      </nav>
    )
  }

  return (
    <nav
      role="tablist"
      aria-label="Admin Navigation"
      style={{
        display: 'flex',
        gap: 8,
        borderBottom: '1px solid var(--border)',
        marginBottom: 8,
      }}
    >
      <NavLink
        to="/admin/users"
        role="tab"
        id="admin-tab-users"
        data-testid="admin-tab-users"
        style={({ isActive }) => ({
          padding: '8px 16px',
          fontSize: 13,
          fontWeight: 600,
          textDecoration: 'none',
          color: isActive ? 'var(--teal)' : 'var(--muted)',
          borderBottom: `2px solid ${isActive ? 'var(--teal)' : 'transparent'}`,
          transition: 'color 0.15s ease, border-color 0.15s ease',
        })}
      >
        User Administration
      </NavLink>
      <NavLink
        to="/admin/features"
        role="tab"
        id="admin-tab-features"
        data-testid="admin-tab-features"
        style={({ isActive }) => ({
          padding: '8px 16px',
          fontSize: 13,
          fontWeight: 600,
          textDecoration: 'none',
          color: isActive ? 'var(--teal)' : 'var(--muted)',
          borderBottom: `2px solid ${isActive ? 'var(--teal)' : 'transparent'}`,
          transition: 'color 0.15s ease, border-color 0.15s ease',
        })}
      >
        Feature Flags
      </NavLink>
    </nav>
  )
}
