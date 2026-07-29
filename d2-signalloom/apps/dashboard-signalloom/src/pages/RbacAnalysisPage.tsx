/**
 * RBAC Analysis — KubeSec-AFM embedded dashboard.
 *
 * Iframes the KubeSec-AFM Next.js dashboard (running in fe-k8s-afm namespace)
 * through the nginx reverse proxy at /afm/. The iframe loads the full AFM
 * dashboard UI with cluster list, RBAC graph, escalation analysis, and
 * remediation recommendations.
 *
 * In demo mode the iframe still loads — AFM runs independently with its own
 * seeded data. In full mode the AFM instance pulls live cluster RBAC.
 */
import { useState } from 'react'

const AFM_PATH = '/afm/dashboard/'

export default function RbacAnalysisPage() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)

  return (
    <div style={{ position: 'relative', height: 'calc(100vh - 56px - 28px)', minHeight: 500 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>RBAC Analysis</h1>
          <p style={{ fontSize: 13, color: 'var(--muted)', margin: 0 }}>
            KubeSec-AFM — formal-methods RBAC privilege escalation &amp; collusion analysis (Z3 bounded model checker)
          </p>
        </div>
        <a
          href={AFM_PATH}
          target="_blank"
          rel="noopener noreferrer"
          style={{
            fontSize: 12, color: 'var(--cyan)', textDecoration: 'none',
            padding: '6px 12px', border: '1px solid var(--border-subtle)',
            borderRadius: 6, transition: 'border-color 0.15s',
          }}
          onMouseEnter={e => (e.currentTarget.style.borderColor = 'var(--cyan)')}
          onMouseLeave={e => (e.currentTarget.style.borderColor = 'var(--border-subtle)')}
        >
          Open in new tab ↗
        </a>
      </div>

      {loading && !error && (
        <div style={{
          position: 'absolute', inset: 0, top: 52,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: 'var(--muted)', fontSize: 13, zIndex: 0,
        }}>
          Loading KubeSec-AFM dashboard…
        </div>
      )}

      {error && (
        <div style={{
          display: 'flex', flexDirection: 'column', alignItems: 'center',
          justifyContent: 'center', height: '60%', gap: 12,
        }}>
          <div style={{ fontSize: 14, color: 'var(--muted)' }}>
            KubeSec-AFM is not reachable. Ensure the AFM platform is deployed:
          </div>
          <code style={{
            background: 'var(--surface2)', padding: '10px 16px', borderRadius: 8,
            fontSize: 12, color: 'var(--cyan)',
          }}>
            make demo-k8s-afm-up
          </code>
        </div>
      )}

      <iframe
        src={AFM_PATH}
        title="KubeSec-AFM Dashboard"
        style={{
          width: '100%',
          height: 'calc(100% - 52px)',
          border: '1px solid var(--border-subtle)',
          borderRadius: 8,
          background: '#0a0e1a',
          display: error ? 'none' : 'block',
        }}
        onLoad={() => setLoading(false)}
        onError={() => { setLoading(false); setError(true) }}
      />
    </div>
  )
}
