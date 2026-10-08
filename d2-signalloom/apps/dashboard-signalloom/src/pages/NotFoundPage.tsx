import React from 'react'
import { Link } from 'react-router-dom'

export function NotFoundPage(): React.JSX.Element {
  return (
    <div
      data-testid="not-found"
      style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        minHeight: '60vh',
        textAlign: 'center',
        padding: '48px 24px',
        gap: 16,
      }}
    >
      <div
        style={{
          fontSize: 64,
          fontWeight: 800,
          color: 'var(--muted)',
          letterSpacing: '-0.03em',
          lineHeight: 1,
        }}
      >
        404
      </div>
      <h1
        style={{
          fontSize: 24,
          fontWeight: 700,
          color: 'var(--text)',
          margin: 0,
        }}
      >
        Page Not Found
      </h1>
      <p
        style={{
          color: 'var(--muted)',
          fontSize: 14,
          maxWidth: 480,
          margin: 0,
          lineHeight: 1.5,
        }}
      >
        The page you requested does not exist, has been moved, or is disabled for your tenant.
      </p>
      <div style={{ marginTop: 8 }}>
        <Link to="/agents" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          Back to Agents
        </Link>
      </div>
    </div>
  )
}

export default NotFoundPage
