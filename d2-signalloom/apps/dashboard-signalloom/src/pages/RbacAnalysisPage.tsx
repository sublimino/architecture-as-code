/**
 * RBAC Analysis — KubeSec-AFM embedded dashboard.
 *
 * Iframes the KubeSec-AFM Next.js dashboard through the nginx reverse proxy at
 * /dashboard/. Same-origin — AFM's asset paths (/dashboard/_next/...) resolve
 * naturally. The iframe loads the full AFM UI: cluster list, RBAC graph,
 * escalation analysis, collusion detection, and remediation recommendations.
 */
import { useCallback, useEffect, useState } from 'react'
import { useAuth0 } from '../auth/oidc'
import { isDemoMode } from '../api/demoMode'

const AFM_DASHBOARD = '/dashboard/'
const AFM_HEALTH = '/afm/health'
const AFM_CLUSTERS = '/afm/clusters'

interface AfmStatus {
  reachable: boolean
  clusterCount: number | null
  checkedAt: Date | null
}

export default function RbacAnalysisPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [iframeLoaded, setIframeLoaded] = useState(false)
  const [status, setStatus] = useState<AfmStatus>({ reachable: false, clusterCount: null, checkedAt: null })
  const [iframeKey, setIframeKey] = useState(0)

  const checkHealth = useCallback(async () => {
    try {
      const [healthRes, clustersRes] = await Promise.all([
        fetch(AFM_HEALTH).then(r => r.ok),
        fetch(AFM_CLUSTERS).then(r => r.ok ? r.json() : null).catch(() => null),
      ])
      setStatus({
        reachable: healthRes,
        clusterCount: Array.isArray(clustersRes) ? clustersRes.length : null,
        checkedAt: new Date(),
      })
    } catch {
      setStatus({ reachable: false, clusterCount: null, checkedAt: new Date() })
    }
  }, [])

  useEffect(() => { checkHealth() }, [checkHealth])

  void getAccessTokenSilently

  const demo = isDemoMode()

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: 'calc(100vh - 56px - 28px)', minHeight: 500 }}>
      {/* Header bar */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12, flexWrap: 'wrap', gap: 8 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>RBAC Analysis</h1>
          <p style={{ fontSize: 13, color: 'var(--muted)', margin: 0, maxWidth: 700 }}>
            KubeSec-AFM — formal-methods RBAC privilege escalation &amp; collusion analysis
            powered by Z3 bounded model checking. Select a cluster below to explore attack paths,
            shared-role pivot points, and min-cut remediation priorities.
          </p>
        </div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          {/* Status indicators */}
          <div style={{ display: 'flex', gap: 12, fontSize: 12, color: 'var(--muted)' }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
              <span style={{
                width: 8, height: 8, borderRadius: '50%',
                background: status.reachable ? '#10B981' : '#EF4444',
              }} />
              AFM {status.reachable ? 'connected' : 'unreachable'}
            </span>
            {status.clusterCount !== null && (
              <span>{status.clusterCount} cluster{status.clusterCount !== 1 ? 's' : ''}</span>
            )}
          </div>
          <button
            onClick={() => { setIframeLoaded(false); setIframeKey(k => k + 1); checkHealth() }}
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '5px 12px' }}
          >
            Reload
          </button>
          <a
            href={AFM_DASHBOARD}
            target="_blank"
            rel="noopener noreferrer"
            style={{
              fontSize: 12, color: 'var(--cyan)', textDecoration: 'none',
              padding: '5px 12px', border: '1px solid var(--border-subtle)',
              borderRadius: 6, transition: 'border-color 0.15s',
            }}
            onMouseEnter={e => (e.currentTarget.style.borderColor = 'var(--cyan)')}
            onMouseLeave={e => (e.currentTarget.style.borderColor = 'var(--border-subtle)')}
          >
            Open full ↗
          </a>
        </div>
      </div>

      {/* Demo mode banner */}
      {demo && (
        <div style={{
          background: 'rgba(245,158,11,0.08)', border: '1px solid rgba(245,158,11,0.25)',
          borderRadius: 6, padding: '8px 14px', marginBottom: 10,
          fontSize: 12, color: '#F59E0B',
        }}>
          Demo mode — AFM is running with seeded sample clusters. Switch to live mode
          for real cluster RBAC analysis.
        </div>
      )}

      {/* Error state */}
      {!status.reachable && status.checkedAt && (
        <div style={{
          flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center',
          justifyContent: 'center', gap: 16,
        }}>
          <div style={{ fontSize: 15, color: 'var(--muted)', textAlign: 'center' }}>
            KubeSec-AFM platform is not reachable
          </div>
          <p style={{ fontSize: 13, color: 'var(--muted)', textAlign: 'center', maxWidth: 440, margin: 0 }}>
            Deploy the AFM platform and seed it with cluster data:
          </p>
          <div style={{
            display: 'flex', flexDirection: 'column', gap: 6,
            background: 'var(--surface2)', padding: '14px 20px', borderRadius: 8,
            fontFamily: 'monospace', fontSize: 12, color: 'var(--cyan)',
          }}>
            <span>make demo-k8s-afm-up</span>
            <span style={{ color: 'var(--muted)' }}># Then reload this page</span>
          </div>
          <button
            onClick={() => { checkHealth(); setIframeKey(k => k + 1) }}
            className="btn btn-primary"
            style={{ fontSize: 13, padding: '8px 20px', marginTop: 8 }}
          >
            Retry connection
          </button>
        </div>
      )}

      {/* Loading spinner */}
      {status.reachable && !iframeLoaded && (
        <div style={{
          position: 'absolute', inset: 0, top: 80,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: 'var(--muted)', fontSize: 13, zIndex: 0,
        }}>
          Loading KubeSec-AFM dashboard…
        </div>
      )}

      {/* AFM iframe */}
      {status.reachable && (
        <iframe
          key={iframeKey}
          src={AFM_DASHBOARD}
          title="KubeSec-AFM Dashboard"
          data-testid="afm-iframe"
          style={{
            flex: 1,
            width: '100%',
            border: '1px solid var(--border-subtle)',
            borderRadius: 8,
            background: '#0a0e1a',
          }}
          onLoad={() => setIframeLoaded(true)}
        />
      )}
    </div>
  )
}
